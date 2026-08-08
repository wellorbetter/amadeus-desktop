# -*- coding: utf-8 -*-
"""
TimePet 一键模型下载/导入 agent（下载 + 校验 + 导入 + 可选写配置）
=================================================================
子命令：
  pick <模型名>   从内置模型仓库一键下载并导入（开箱即用）
       --list     列出内置模型仓库（名称 / 简介 / 格式）
       --set-config  下载后直接写入 config.json，重启即生效
  download --url URL [--name NAME] [--target user|exe] [--set-config]
       --url 必填：模型 zip 下载链接由使用者自行提供，脚本不内置 zip 链接。
  list           列出已安装模型（复用 import_model）

用法示例：
  python tools/download_model.py pick --list
  python tools/download_model.py pick shizuku --set-config
  python tools/download_model.py pick hibiki
  python tools/download_model.py download --url https://example.com/model.zip --set-config

内置模型仓库说明：
  - 数据源：https://github.com/hacxy/l2d-models（开源免费模型合集），
    直链 CDN：https://model.hacxy.cn/
  - 只收录当前桌宠引擎能显示的 Cubism 2.1（.model.json）模型；
    model3.json（Cubism 5）暂不支持，故不收录。
  - 模型版权归原作者所有，仅限个人本地学习研究；
    请勿商用 / 二次分发 / 重新打包发布（与仓库 models/ 不入库策略一致）。
"""
import argparse
import json
import os
import shutil
import sys
import tempfile
import urllib.parse
import urllib.request
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import import_model as im

# 内置模型仓库（hacxy/l2d-models 中可用的 Cubism 2.1 模型）
MODEL_CDN = "https://model.hacxy.cn/"

CATALOG = {
    "shizuku": {
        "title": "小雫 Shizuku",
        "desc": "官方示例·经典少女，点按/捏合动作带音效",
        "kind": "Cubism 2.1",
        "json": "shizuku/shizuku.model.json",
    },
    "haruto": {
        "title": "春 Haruto",
        "desc": "官方示例·和风少年",
        "kind": "Cubism 2.1",
        "json": "haruto/haruto.model.json",
    },
    "hibiki": {
        "title": "响 Hibiki",
        "desc": "官方示例·元气少女，动作带音效",
        "kind": "Cubism 2.1",
        "json": "hibiki/hibiki.model.json",
    },
    "wed_16": {
        "title": "古风婚服少女",
        "desc": "同人模型·古风角色，含点按语音",
        "kind": "Cubism 2.1",
        "json": "wed_16/wed_16.model.json",
    },
    "z16": {
        "title": "z16",
        "desc": "官方示例·极简人像（体积最小，适合试手）",
        "kind": "Cubism 2.1",
        "json": "z16/z16.model.json",
    },
}

# 需要下载的文件扩展名（排除模型 json 里的占位符/标签字符串）
FILE_EXTS = (
    ".moc", ".mtn", ".mp3", ".wav", ".ogg", ".png", ".jpg", ".jpeg",
    ".json", ".tga", ".bmp",
)
SKIP_MARKERS = ("D_REF.", "Sample", "Config", "{", "}", "http")


def is_ref_candidate(s):
    if not s or not isinstance(s, str):
        return False
    low = s.lower()
    if not low.endswith(FILE_EXTS):
        return False
    if any(m in s for m in SKIP_MARKERS):
        return False
    return True


def collect_file_refs(cfg):
    """递归收集模型 json 里的相对文件引用（去重、保序）。"""
    refs = []

    def walk(obj):
        if isinstance(obj, dict):
            for k, v in obj.items():
                if isinstance(k, str) and k.lower() in ("name", "version", "title"):
                    continue
                walk(v)
        elif isinstance(obj, list):
            for it in obj:
                walk(it)
        elif isinstance(obj, str):
            if is_ref_candidate(obj):
                refs.append(obj)

    walk(cfg)
    seen = set()
    out = []
    for r in refs:
        r = r.replace("\\", "/")
        if r not in seen:
            seen.add(r)
            out.append(r)
    return out


def cdn_url(rel_path):
    """把模型相对路径（相对 CDN 模型目录）拼成直链，逐段 URL 编码。"""
    parts = [urllib.parse.quote(seg) for seg in rel_path.split("/") if seg]
    return MODEL_CDN + "/".join(parts)


def fetch_file(url, dest, show_progress=True):
    """下载单个文件到 dest（自动建目录，跳过已存在），失败抛异常。"""
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": "TimePet/1.0"})
    with urllib.request.urlopen(req, timeout=120) as resp, open(dest, "wb") as f:
        total = int(resp.headers.get("Content-Length") or 0)
        done = 0
        while True:
            chunk = resp.read(1 << 16)
            if not chunk:
                break
            f.write(chunk)
            done += len(chunk)
    if show_progress:
        print("  [OK] %s (%d KB)" % (os.path.basename(dest), os.path.getsize(dest) // 1024))


def download(url, dest_zip):
    print("下载模型 : %s" % url)
    req = urllib.request.Request(url, headers={"User-Agent": "TimePet/1.0"})
    with urllib.request.urlopen(req, timeout=120) as resp, open(dest_zip, "wb") as f:
        total = int(resp.headers.get("Content-Length") or 0)
        done = 0
        while True:
            chunk = resp.read(1 << 16)
            if not chunk:
                break
            f.write(chunk)
            done += len(chunk)
            if total:
                pct = done * 100 // total
                sys.stdout.write("\r  进度 %3d%% (%d/%d KB)" % (pct, done // 1024, total // 1024))
                sys.stdout.flush()
    sys.stdout.write("\n")
    print("下载完成 : %s (%d KB)" % (dest_zip, os.path.getsize(dest_zip) // 1024))


def extract_safe(zip_path, out_dir):
    """解压并定位模型配置目录（防 zip-slip）。"""
    with zipfile.ZipFile(zip_path) as zf:
        root = os.path.normpath(out_dir)
        for member in zf.infolist():
            target = os.path.normpath(os.path.join(root, member.filename))
            if not target.startswith(root):
                raise RuntimeError("zip 包含非法路径: %s" % member.filename)
        zf.extractall(out_dir)
    cfg = im.find_model_json(out_dir)
    if cfg is None:
        raise RuntimeError("未找到模型配置（需要 *.model.json 或 model3.json）")
    return os.path.dirname(cfg)


def print_catalog():
    print("内置模型仓库（hacxy/l2d-models → model.hacxy.cn，仅收录 Cubism 2.1 可用模型）")
    print("=" * 70)
    for name, info in CATALOG.items():
        print("  %-10s %-14s %s" % (name, info["title"], info["desc"]))
    print("=" * 70)
    print("用法：python tools/download_model.py pick <模型名> [--set-config]")


def cmd_pick(args):
    if args.list:
        print_catalog()
        return
    name = args.name_key
    if name not in CATALOG:
        print("错误：未知模型名「%s」。可用模型：" % name)
        for n in CATALOG:
            print("  - %s（%s）" % (n, CATALOG[n]["title"]))
        sys.exit(1)
    info = CATALOG[name]
    rel = info["json"]
    tmp = tempfile.mkdtemp(prefix="timepet_pick_")
    try:
        model_dir = os.path.join(tmp, name)
        os.makedirs(model_dir, exist_ok=True)
        cfg_file = os.path.join(model_dir, os.path.basename(rel))
        print("== 从内置仓库下载「%s（%s）」==" % (info["title"], name))
        print("模型 json : %s" % cdn_url(rel))
        fetch_file(cdn_url(rel), cfg_file)
        cfg = im.load_json(cfg_file)
        kind = im.model_kind(cfg_file)
        if kind != "cubism2":
            print("错误：内置清单只收录 Cubism 2.1 模型，请改用 download --url 导入该 model3 模型。")
            sys.exit(1)
        refs = collect_file_refs(cfg)
        print("引用资源 : %d 个文件，开始下载…" % len(refs))
        failed = []
        for ref in refs:
            dest = os.path.join(model_dir, *ref.split("/"))
            if os.path.isfile(dest):
                continue
            try:
                fetch_file(cdn_url(rel.rsplit("/", 1)[0] + "/" + ref), dest)
            except Exception as e:
                failed.append(ref)
                print("  [X] %s (%s)" % (ref, e))
        missing, total, sounds = im.resolve_refs(model_dir, cfg, kind)
        missing = list(dict.fromkeys(missing))
        if missing:
            print("警告：%d/%d 个引用资源未下载成功：" % (len(missing), total))
            for m in missing[:10]:
                print("  - %s" % m)
            critical = [m for m in missing if m.lower().endswith((".moc", ".png", ".jpg"))]
            if critical:
                print("错误：模型核心资源（moc/贴图）缺失，导入失败。")
                sys.exit(1)
        print("资源校验 : 通过（引用 %d，音效引用 %d 处）" % (total, sounds))
        ns = argparse.Namespace(
            model=model_dir,
            name=args.name or name,
            target=args.target,
            set_config=args.set_config,
        )
        im.cmd_import(ns)
        print("")
        print("开箱即用完成：模型已安装到 %s" % os.path.join(im.appdata_timepet_dir(), "models"))
        if args.set_config:
            print("已写入 config.json，重启桌宠即可看到新模型。")
        else:
            print("如需立刻使用，可加 --set-config 重新执行，或在设置里选择该模型后重启。")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def cmd_download(args):
    tmp = tempfile.mkdtemp(prefix="timepet_model_")
    try:
        zip_path = os.path.join(tmp, "model.zip")
        download(args.url, zip_path)
        extracted = os.path.join(tmp, "extracted")
        os.makedirs(extracted, exist_ok=True)
        model_dir = extract_safe(zip_path, extracted)
        print("解压完成 : %s" % model_dir)
        ns = argparse.Namespace(
            model=model_dir,
            name=args.name,
            target=args.target,
            set_config=args.set_config,
        )
        im.cmd_import(ns)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    print("=" * 60)
    print("TimePet 一键模型下载/导入 agent")
    print("=" * 60)
    print("版权提醒：第三方同人二创模型仅限个人本地学习；")
    print("请勿商用 / 二次分发 / 重新打包发布。")
    print("=" * 60)
    ap = argparse.ArgumentParser(description="TimePet 一键下载并导入模型")
    sub = ap.add_subparsers(dest="cmd")

    p_pick = sub.add_parser("pick", help="从内置模型仓库一键下载并导入（开箱即用）")
    p_pick.add_argument("name_key", nargs="?", default=None, help="模型名，见 pick --list")
    p_pick.add_argument("--list", action="store_true", help="列出内置模型仓库")
    p_pick.add_argument("--name", default=None, help="导入后的文件夹名（默认同模型名）")
    p_pick.add_argument("--target", choices=["user", "exe"], default="user",
                        help="目标目录：user=%APPDATA%\\timepet\\models（默认）；exe=桌宠目录\\models\\")
    p_pick.add_argument("--set-config", action="store_true",
                        help="同时把模型写入 config.json（无需手动切换）")

    p = sub.add_parser("download", help="下载并导入模型（--url 必填，不内置 zip 链接）")
    p.add_argument("--url", required=True, help="模型 zip 下载链接（必填，见 README「模型导入」）")
    p.add_argument("--name", default=None, help="导入后的文件夹名（默认从模型 json 推断）")
    p.add_argument("--target", choices=["user", "exe"], default="user",
                   help="目标目录：user=%APPDATA%\\timepet\\models（默认）；exe=桌宠目录\\models\\")
    p.add_argument("--set-config", action="store_true",
                   help="同时把模型写入 config.json（无需手动切换）")
    sub.add_parser("list", help="列出已安装模型")
    args = ap.parse_args()
    if args.cmd == "pick":
        if args.name_key is None and not args.list:
            print_catalog()
            sys.exit(0)
        cmd_pick(args)
    elif args.cmd == "download":
        cmd_download(args)
    elif args.cmd == "list":
        im.cmd_list()
    else:
        ap.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()