# -*- coding: utf-8 -*-
"""
TimePet 一键模型下载/导入 agent（下载 + 校验 + 导入 + 可选写配置）
=================================================================
子命令：
  download --url URL [--name NAME] [--target user|exe] [--set-config]
     --url 必填：模型 zip 下载链接由使用者自行提供，脚本不内置任何
     第三方模型链接（与上游 Amadeus 项目做法一致）。
  list    列出已安装模型（复用 import_model）

用法示例：
  python tools/download_model.py download --url https://example.com/model.zip --name shizuku
  python tools/download_model.py download --url https://example.com/model.zip --set-config

版权与合规（务必阅读）：
  - 模型链接指向第三方同人二创 Live2D 模型时，仅限个人本地学习研究；
    请勿商用、二次分发、重新打包发布（与仓库 models/ 不入库策略一致）。
  - 请使用你自己拥有或已获授权的模型 zip。
"""
import argparse
import os
import shutil
import sys
import tempfile
import urllib.request
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import import_model as im


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


def cmd_download(args):
    tmp = tempfile.mkdtemp(prefix="timepet_model_")
    try:
        zip_path = os.path.join(tmp, "model.zip")
        download(args.url, zip_path)
        extracted = os.path.join(tmp, "extracted")
        os.makedirs(extracted, exist_ok=True)
        model_dir = extract_safe(zip_path, extracted)
        print("解压完成 : %s" % model_dir)
        # 复用 import_model 的导入流程（构造与 cmd_import 兼容的 Namespace）
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
    p = sub.add_parser("download", help="下载并导入模型（--url 必填，不内置模型链接）")
    p.add_argument("--url", required=True, help="模型 zip 下载链接（必填，见 README「模型导入」）")
    p.add_argument("--name", default=None, help="导入后的文件夹名（默认从模型 json 推断）")
    p.add_argument("--target", choices=["user", "exe"], default="user",
                   help="目标目录：user=%APPDATA%\\timepet\\models（默认）；exe=桌宠目录\\models\\")
    p.add_argument("--set-config", action="store_true",
                   help="同时把模型写入 config.json（无需手动切换）")
    sub.add_parser("list", help="列出已安装模型")
    args = ap.parse_args()
    if args.cmd == "download":
        cmd_download(args)
    elif args.cmd == "list":
        im.cmd_list()
    else:
        ap.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
