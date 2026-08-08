# -*- coding: utf-8 -*-
"""
TimePet 模型导入工具（教程 agent 核心）
========================================
子命令：
  import  <模型文件夹或model.json路径>  导入模型（默认子命令，可省略 import）
  list                                 列出已安装模型（含音效数量/当前激活）
  switch <模型名或json路径>             切换当前使用的模型
  status                               查看当前模型 / 人格 / 数据服务状态
  check  <模型文件夹或json路径>         只校验不复制（资源完整性 + 音效）

用法示例：
  python tools/import_model.py import D:\\models\\shizuku
  python tools/import_model.py import D:\\models\\shizuku --set-config
  python tools/import_model.py D:\\models\\shizuku            # import 可省略
  python tools/import_model.py list
  python tools/import_model.py switch shizuku
  python tools/import_model.py status

说明：
  - 模型文件不入库、不入安装包，请使用合规模型（版权自行确认）。
  - 音效来自模型自身动作定义（motions 里的 sound 引用，如 kurisu 的 sounds/*.mp3）；
    没有音效文件的模型保持无声，这是模型决定的，不是程序问题。
"""
import argparse
import json
import os
import shutil
import sys

AUDIO_EXTS = (".mp3", ".wav", ".ogg", ".m4a", ".aac")


def find_model_json(root):
    """在目录里递归找模型配置：优先 .model.json（Cubism 2.1），其次 model3.json。"""
    if os.path.isfile(root):
        return root
    hits = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
        for fn in filenames:
            low = fn.lower()
            if low.endswith(".model.json") or low.endswith("model3.json"):
                hits.append(os.path.join(dirpath, fn))
    if not hits:
        return None
    # 优先 Cubism 2.1
    for h in hits:
        if h.lower().endswith(".model.json"):
            return h
    return hits[0]


def load_json(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def model_kind(cfg_path):
    low = os.path.basename(cfg_path).lower()
    if low.endswith("model3.json"):
        return "cubism5"
    return "cubism2"


def count_audio_files(model_dir):
    """统计模型目录里的音效文件数量（更直观，包含未被 motions 引用的）。"""
    n = 0
    for dirpath, dirnames, filenames in os.walk(model_dir):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
        for fn in filenames:
            if fn.lower().endswith(AUDIO_EXTS):
                n += 1
    return n


def resolve_refs(model_dir, cfg, kind):
    """从模型配置解析所有引用文件，返回 (缺失列表, 总数, 引用的音效数量)。"""
    missing = []
    total = 0
    sounds = 0

    def check(ref):
        nonlocal total
        if not ref:
            return
        total += 1
        p = os.path.normpath(os.path.join(model_dir, ref))
        if not os.path.isfile(p):
            missing.append(ref)

    if kind == "cubism5":
        fr = cfg.get("FileReferences") or {}
        check(fr.get("Moc"))
        for t in fr.get("Textures") or []:
            check(t)
        check(fr.get("Physics"))
        check(fr.get("Pose"))
        check(fr.get("DisplayInfo"))
        for group in (fr.get("Motions") or {}).values():
            for m in group:
                check(m.get("File"))
                if m.get("Sound"):
                    sounds += 1
        for e in (fr.get("Expressions") or []):
            check(e.get("File"))
    else:
        check(cfg.get("model"))
        for t in cfg.get("textures") or []:
            check(t)
        check(cfg.get("physics"))
        check(cfg.get("pose"))
        for group in (cfg.get("motions") or {}).values():
            for m in group:
                check(m.get("file"))
                if m.get("sound"):
                    sounds += 1
        for e in cfg.get("expressions") or []:
            check(e.get("file"))

    return missing, total, sounds


def appdata_timepet_dir():
    base = os.environ.get("APPDATA") or os.path.join(
        os.path.expanduser("~"), "AppData", "Roaming")
    return os.path.join(base, "timepet")


def config_path():
    return os.path.join(appdata_timepet_dir(), "config.json")


def read_config():
    cfg_file = config_path()
    if os.path.isfile(cfg_file):
        with open(cfg_file, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    return {}


def write_config(cfg):
    cfg_file = config_path()
    with open(cfg_file, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=4)


def set_model_path(model_json_path):
    """把模型 json 绝对路径写入 config.json 的 appearance.modelPath（不存在的键自动补全）。"""
    cfg = read_config()
    cfg.setdefault("appearance", {})["modelPath"] = model_json_path
    write_config(cfg)
    print("  [config] appearance.modelPath = %s" % model_json_path)


def models_roots():
    user_root = os.path.join(appdata_timepet_dir(), "models")
    exe_root = os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "models")
    return [("user", user_root), ("exe", exe_root)]


def scan_installed():
    """扫描已安装模型，返回 [{name, dir, cfg_file, kind, audio}]。"""
    out = []
    for label, root in models_roots():
        if not os.path.isdir(root):
            continue
        for d in sorted(os.listdir(root)):
            dd = os.path.join(root, d)
            if not os.path.isdir(dd):
                continue
            cfg_file = find_model_json(dd)
            if not cfg_file:
                continue
            kind = model_kind(cfg_file)
            try:
                cfg = load_json(cfg_file)
            except Exception:
                cfg = {}
            audio = count_audio_files(dd)
            out.append({
                "name": d,
                "dir": dd,
                "cfg_file": cfg_file,
                "kind": kind,
                "audio": audio,
            })
    return out


def cmd_import(args):
    src = os.path.abspath(args.model)
    if not os.path.exists(src):
        print("错误：路径不存在 -> %s" % src)
        sys.exit(1)

    cfg_file = find_model_json(src)
    if not cfg_file:
        print("错误：未找到模型配置文件（需要 *.model.json 或 model3.json）")
        sys.exit(1)

    kind = model_kind(cfg_file)
    model_dir = os.path.dirname(cfg_file)
    cfg = load_json(cfg_file)

    base = os.path.basename(cfg_file)
    if base.lower().endswith(".model.json"):
        name = args.name or base[:-len(".model.json")]
    else:
        name = args.name or os.path.splitext(base)[0]
    missing, total, sounds = resolve_refs(model_dir, cfg, kind)
    audio_files = count_audio_files(model_dir)

    print("模型配置 : %s" % cfg_file)
    print("模型格式 : %s" % ("Cubism 5 (model3.json)" if kind == "cubism5" else "Cubism 2.1 (.model.json)"))
    print("引用资源 : 共 %d 个，缺失 %d 个" % (total, len(missing)))
    print("音效文件 : 目录内 %d 个（动作引用 %d 处）" % (audio_files, sounds))
    if missing:
        print("缺失文件 :")
        for m in missing[:10]:
            print("  - %s" % m)
        print("错误：模型资源不完整，请先补齐后再导入（同目录下需包含贴图/动作等资源）。")
        sys.exit(1)

    if kind == "cubism5":
        print("警告：当前桌宠仅支持 Cubism 2.1（*.model.json）。"
              "model3.json 模型会显示不支持提示，请使用 Cubism 2.1 模型。")
    if audio_files == 0:
        print("提示：该模型没有音效文件（motions 未引用声音），对话时保持无声是正常的。")

    if args.target == "user":
        target_root = os.path.join(appdata_timepet_dir(), "models")
    else:
        target_root = models_roots()[1][1]
    os.makedirs(target_root, exist_ok=True)

    dest = os.path.join(target_root, name)
    if os.path.abspath(model_dir) == os.path.abspath(dest):
        print("模型已在目标目录，无需复制。")
    else:
        if os.path.exists(dest):
            print("目标已存在，先移除旧副本：%s" % dest)
            shutil.rmtree(dest)
        print("复制中... %s -> %s" % (model_dir, dest))
        shutil.copytree(model_dir, dest)

    dest_cfg = os.path.join(dest, os.path.basename(cfg_file))
    print("完成！模型已导入：%s" % dest)

    if args.set_config:
        set_model_path(dest_cfg)
        print("  [config] 已写入，重启桌宠即可立即使用该模型。")
    else:
        print("  [提示] 重启桌宠后会自动扫描该目录；"
              "也可运行「python tools/import_model.py switch %s」或"
              "在设置「外观 → 模型路径」里填写：%s" % (name, dest_cfg))


def cmd_list():
    installed = scan_installed()
    if not installed:
        print("未找到已安装模型。请先运行：python tools/import_model.py import <模型路径>")
        return
    cfg = read_config()
    active = (cfg.get("appearance") or {}).get("modelPath", "")
    for label, root in models_roots():
        if not os.path.isdir(root):
            continue
        print("目录[%s] %s" % (label, root))
        found = False
        root_norm = os.path.normpath(root)
        for it in installed:
            cfg_dir = os.path.dirname(os.path.normpath(it["cfg_file"]))
            if os.path.commonpath([root_norm, cfg_dir]) != root_norm:
                continue
            found = True
            mark = " [当前]" if os.path.normpath(it["cfg_file"]) == os.path.normpath(active) else ""
            print("  %-14s %-11s 音效 %2d 个%s" % (
                it["name"], "Cubism 2.1" if it["kind"] == "cubism2" else "Cubism 5",
                it["audio"], mark))
        if not found:
            print("  （空）")
    print("当前激活：%s" % (active or "自动扫描（无显式配置）"))


def cmd_switch(target):
    installed = scan_installed()
    target_path = os.path.abspath(target)
    hit = None
    if os.path.exists(target_path):
        hit = find_model_json(target_path)
    if hit is None:
        # 按名称匹配（支持大小写/路径分隔符容错）
        low = target.strip().lower().replace("\\", "/").rstrip("/")
        for it in installed:
            if it["name"].lower() == low or os.path.basename(it["cfg_file"]).lower() == low:
                hit = it["cfg_file"]
                break
    if hit is None:
        print("错误：找不到模型「%s」。先运行 list 查看已安装模型，或传模型 json 的绝对路径。" % target)
        sys.exit(1)
    set_model_path(hit)
    kind = model_kind(hit)
    print("已切换为：%s（%s）" % (hit, "Cubism 5" if kind == "cubism5" else "Cubism 2.1"))
    if kind == "cubism5":
        print("警告：当前桌宠仅支持 Cubism 2.1，该模型可能无法显示。")
    print("重启桌宠后生效；或在设置里确认「外观 → 模型路径」。")


def cmd_check(path):
    src = os.path.abspath(path)
    if not os.path.exists(src):
        print("错误：路径不存在 -> %s" % src)
        sys.exit(1)
    cfg_file = find_model_json(src)
    if not cfg_file:
        print("错误：未找到模型配置文件（需要 *.model.json 或 model3.json）")
        sys.exit(1)
    kind = model_kind(cfg_file)
    cfg = load_json(cfg_file)
    missing, total, sounds = resolve_refs(os.path.dirname(cfg_file), cfg, kind)
    audio_files = count_audio_files(os.path.dirname(cfg_file))
    print("模型配置 : %s" % cfg_file)
    print("模型格式 : %s" % ("Cubism 5 (model3.json)" if kind == "cubism5" else "Cubism 2.1 (.model.json)"))
    print("引用资源 : 共 %d 个，缺失 %d 个" % (total, len(missing)))
    print("音效文件 : 目录内 %d 个（动作引用 %d 处）" % (audio_files, sounds))
    if missing:
        print("缺失文件 :")
        for m in missing[:10]:
            print("  - %s" % m)
        print("结论：资源不完整，请补齐后再导入。")
        sys.exit(1)
    if kind == "cubism5":
        print("结论：资源完整，但 Cubism 5 暂不被桌宠支持。")
    else:
        print("结论：资源完整，可以直接导入使用。")


def cmd_status():
    cfg = read_config()
    appearance = cfg.get("appearance") or {}
    ai = cfg.get("ai") or {}
    active = appearance.get("modelPath", "")
    installed = scan_installed()
    print("配置目录 : %s" % appdata_timepet_dir())
    if active:
        print("显式模型 : %s（存在=%s）" % (active, os.path.isfile(active)))
    else:
        print("显式模型 : 无（自动扫描）")
        for it in installed:
            print("  - 自动扫描可用：%s" % it["cfg_file"])
    print("已装模型 : %d 个" % len(installed))
    for it in installed:
        flag = "  [当前]" if active and os.path.normpath(it["cfg_file"]) == os.path.normpath(active) else ""
        print("  - %-12s %-12s 音效 %2d 个%s" % (
            it["name"], "Cubism 2.1" if it["kind"] == "cubism2" else "Cubism 5",
            it["audio"], flag))
    soul_path = os.path.join(appdata_timepet_dir(), "soul.md")
    print("人格 soul : %s" % (soul_path if os.path.isfile(soul_path) else "未找到（使用内置默认人格）"))
    if ai.get("soulFile"):
        print("           显式人格：%s（存在=%s）" % (ai["soulFile"], os.path.isfile(ai["soulFile"])))
    # 数据服务连通性（快速探测，不影响其余输出）
    try:
        import urllib.request
        req = urllib.request.Request("http://127.0.0.1:8788/api/context", method="GET")
        with urllib.request.urlopen(req, timeout=2) as r:
            print("数据服务 : http://127.0.0.1:8788 可达（HTTP %d）—— 开启后她更懂你的活动" % r.status)
    except Exception as e:
        print("数据服务 : http://127.0.0.1:8788 不可达（%s）—— 未开也能聊天/整点问候，但感知不到你的活动" % type(e).__name__)


def main():
    parser = argparse.ArgumentParser(description="TimePet 模型导入/管理工具")
    sub = parser.add_subparsers(dest="cmd")

    p_import = sub.add_parser("import", help="导入模型（默认）")
    p_import.add_argument("model", help="模型文件夹或模型 json 文件路径")
    p_import.add_argument("--target", choices=["user", "exe"], default="user",
                          help="目标目录：user=%APPDATA%\\timepet\\models（默认，免权限）；exe=桌宠旁 models\\")
    p_import.add_argument("--set-config", action="store_true",
                          help="同时把模型写入 config.json（无需手动切换）")
    p_import.add_argument("--name", default=None, help="导入后的文件夹名（默认取模型 json 文件名）")

    p_list = sub.add_parser("list", help="列出已安装模型")
    p_switch = sub.add_parser("switch", help="切换当前模型")
    p_switch.add_argument("target", help="已安装模型名（如 shizuku）或模型 json 绝对路径")
    p_check = sub.add_parser("check", help="只校验模型资源，不复制")
    p_check.add_argument("model", help="模型文件夹或模型 json 文件路径")
    sub.add_parser("status", help="查看当前模型/人格/数据服务状态")

    args = parser.parse_args()

    # 兼容旧用法：第一个位置参数是路径时视为 import
    if args.cmd is None and getattr(args, "model", None):
        args.cmd = "import"
    if args.cmd is None:
        parser.print_help()
        sys.exit(0)

    if args.cmd == "import":
        cmd_import(args)
    elif args.cmd == "list":
        cmd_list()
    elif args.cmd == "switch":
        cmd_switch(args.target)
    elif args.cmd == "check":
        cmd_check(args.model)
    elif args.cmd == "status":
        cmd_status()


if __name__ == "__main__":
    main()
