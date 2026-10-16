# Chromium Full Source Tarballs

为信创项目提供包含 **Chromium 完整源码、工具链、Linux Sysroot 及构建依赖**的一体化源码包，支持 Chromium 的**离线移植、交叉编译与长期归档**。

本项目不维护 Chromium 分支，而是根据指定 Chromium 版本，通过官方 `depot_tools` / `gclient` 工作流获取源码及构建依赖。

支持国产芯片：

* x86: 兆芯、海光
* arm64: 飞腾、华为麒麟、瑞芯微等
* loongarch64: 龙芯（新世界 loong64 / 旧世界 la64）

龙芯版本已经包含龙芯官方sysroot、llvm、补丁包。

本项目源码包适合在 X86 架构系统上交叉编译 arm64/loong64（新世界）/la64（旧世界）的 Chromium，也可以编译面向兆芯和海光以及 Intel 和 AMD 的 Chromium。

构建系统可选 UOS V20、deepin v25、Ubuntu 24.04。理论上其他 Linux 发行版也可以，但未经验证。如果发现构建问题，欢迎提 issue。

## 项目背景

Chromium 的官方源码获取方式依赖 `depot_tools`、`fetch`、`gclient sync` 和 `gclient runhooks`。除了 Chromium 主仓库之外，构建过程中还会获取大量 `third_party` 依赖、Clang/LLVM、Rust、Sysroot 以及其他构建工具。

对于信创操作系统、国产 CPU 平台以及网络受限的构建环境而言，直接从 Chromium 官方仓库重新获取这些依赖存在以下问题：

* 源码及第三方依赖数量庞大；
* 构建依赖较多，首次准备环境耗时较长；
* 部分构建工具由 Chromium hooks 自动下载；
* 网络受限或完全离线的环境无法直接执行 `gclient sync` / `gclient runhooks`；

因此，本项目将指定 Chromium 版本所需的源码及 Chromium 构建依赖统一归档，形成可以直接分发和离线使用的源码包。

源码包中会保留 Chromium 的具体版本和 Git revision 信息，以便后续确认源码来源。

## 包含内容

根据 Chromium 版本及目标架构，生成的源码包主要包含：

```text
Chromium source
Chromium third_party dependencies
Clang / LLVM
Rust toolchain
Linux Sysroot
depot_tools Chromium 构建工具
```

其中工具链和其他构建依赖主要来自 Chromium `DEPS`、hooks 以及 Chromium 自身的构建配置。

### ARM64

对于 ARM64 版本，源码包会包含对应的 Linux ARM64 Sysroot，以支持交叉编译。

例如：

```text
chromium-full-src-140.0.7339.82-linux-arm64.tar.zst
```

该版本面向 Linux ARM64 Chromium 的移植和构建。

### loong64 / la64

loongarch64 不是 Chromium 官方支持的目标架构，Chromium 官方不提供对应的 Sysroot 和 Clang/LLVM 工具链。

因此 loongarch64 架构的源码包使用 Loongnix 提供的构建资源：Sysroot、Toolchain 和 Patch。

龙芯新旧世界在 ABI 层面存在区别（3a5000/3a6000 处理器都支持，但只能是其中一种），可以通过 `readelf -h a.out` 查看输出中 Flags 字段判别：`0x3` 表示旧世界，`0x43` 表示新世界。源码包架构标识：

* `loong64`：新世界（new world），工具链替换 `third_party/llvm-build/Release+Asserts`
* `la64`：旧世界（old world），LLVM 20 与 Rust 交叉工具链打包在包内 `opt/` 目录（patch 和 `build/cross-build.sh` 硬编码 `/opt/` 路径，构建前需复制到 `/opt/`）

同一个适配 patch 同时覆盖新旧世界，通过 GN 参数 `use_nw` 区分。

目前支持的版本：

| 世界 | Chromium 版本 | Sysroot | LLVM | Patch |
| --- | --- | --- | --- | --- |
| 新世界 (loong64) | 126.0.6478.x | [debian_bullseye_loongarch64-sysroot.tar.bz2](http://ftp.loongnix.cn/browser/build/sysroot/debian_bullseye_loongarch64-sysroot.tar.bz2) | [Release+Asserts-126.tar.bz2](http://ftp.loongnix.cn/browser/build/toolchain/Release+Asserts-126.tar.bz2) | [chromium126 patch](https://github.com/loongson/chromium/raw/loongarch-patches/chromium126/0001-la64-cross-CH126-Add-loongarch-build-support-for-old-new-w.patch) |
| 新世界 (loong64) | 150.0.7871.211 | [debian_bullseye_loongarch64-sysroot.tar.bz2](http://ftp.loongnix.cn/browser/build/sysroot/debian_bullseye_loongarch64-sysroot.tar.bz2) | [Release+Asserts-150.tar.bz2](http://ftp.loongnix.cn/browser/build/toolchain/Release+Asserts-150.tar.bz2) | [chromium150 patch](https://github.com/loongson/chromium/raw/loongarch-patches/chromium150/0001-la64-cross-CH150-Add-loongarch-build-support-for-old-new-w.patch) |
| 旧世界 (la64) | 150.0.7871.211 | [debian_bullseye_loong64-sysroot.tar.bz2](http://ftp.loongnix.cn/browser/build/sysroot/debian_bullseye_loong64-sysroot.tar.bz2) | [llvm-toolchain_20.1.8-1_amd64-linux-gnu_debian-10.tar.gz](http://ftp.loongnix.cn/toolchain/llvm/llvm20/llvm-toolchain_20.1.8-1_amd64-linux-gnu_debian-10.tar.gz)（另含 [rust-1.92.0-nightly-cross.tar.bz2](http://ftp.loongnix.cn/browser/build/toolchain/rust-1.92.0-nightly-cross.tar.bz2)） | [chromium150 patch](https://github.com/loongson/chromium/raw/loongarch-patches/chromium150/0001-la64-cross-CH150-Add-loongarch-build-support-for-old-new-w.patch) |

资源来源：[loongson/chromium loongarch-patches 分支](https://github.com/loongson/chromium/tree/loongarch-patches)。

#### GitHub Actions 网络问题

`ftp.loongnix.cn` 在 GitHub Actions 海外 runner 上经常无法连通（connect timeout）。脚本下载时会依次尝试以下源，任一成功即可：

1. `LOONGNIX_MIRROR_BASE` 镜像（可选）
2. `https://ftp.loongnix.cn/...`（HTTPS）
3. `http://ftp.loongnix.cn/...`（HTTP）

推荐在 GitHub 仓库 Release 中托管 Loongnix 资源镜像（建议 tag：`loongnix-resources`，上传对应文件，单文件需小于 2GiB），然后设置仓库变量：

```
Settings → Secrets and variables → Actions → Variables → New repository variable
Name:  LOONGNIX_MIRROR_BASE
Value: https://github.com/mogoweb/chromium-full-src-tarballs/releases/download/loongnix-resources
```

workflow 会自动读取该变量（`${{ vars.LOONGNIX_MIRROR_BASE }}`），本地运行时也可以通过环境变量传入。

本地或国内环境下载大文件时可调整超时与重试次数：

```bash
DOWNLOAD_TIMEOUT_SECS=28800 DOWNLOAD_RETRIES=8 ./package_chromium_full.sh 150.0.7871.211 loong64
```

## 恢复完整源码包

下载所有分片后，可以使用 `cat` 合并：

```bash
cat chromium-full-src-140.0.7339.82-linux-arm64.tar.zst.part-* \
    > chromium-full-src-140.0.7339.82-linux-arm64.tar.zst
```

然后验证完整文件：

```bash
sha256sum -c SHA256SUMS
```

验证通过后解压：

```bash
tar \
    --use-compress-program=zstd \
    -xf chromium-full-src-140.0.7339.82-linux-arm64.tar.zst
```

解压后：

```text
chromium-full-src-140.0.7339.82-linux-arm64/
└── src/
└── depot_tools/
```

## 构建

源码包的主要使用场景是网络受限或完全离线的 Chromium 构建环境。

在具有对应宿主机基础依赖的 Linux 环境中，解压源码包后，可以直接进入：

```bash
cd chromium-full-src-140.0.7339.82-linux-arm64/src
```

在 Ubuntu 系统上，可以运行如下命令安装构建依赖包：

```bash
./build/install-build-deps.sh
```

设置chromium构建工具 gn/ninja 的路径：

```bash
export PATH=$(pwd)/depot_tools:$PATH
```

然后根据实际构建目标生成 GN 配置。

例如 ARM64：

```bash
gn gen out/Release --args='
  is_debug=false
  target_os="linux"
  target_cpu="arm64"
  is_component_build=false
'
```

执行构建：

```bash
autoninja -C out/Release chrome
```

### 编译 loong64（新世界）架构 Chromium

龙芯公司提供的 patch 中已经包含了构建脚本，直接运行脚本就可以：
```
./build/cross-build.sh loongarch64 
```

> 126 及之后版本支持参数配置新旧世界兼容构建（`use_nw`），详见
> [loongson/chromium loongarch-patches](https://github.com/loongson/chromium/tree/loongarch-patches)
> 对应 chromiumXXX 目录中的 README.md。

### 编译 la64（旧世界）架构 Chromium

旧世界使用 Loongnix 提供的 LLVM 20 工具链和 Rust 交叉工具链，二者已打包在源码包的 `opt/` 目录下（patch 的 `build/config/clang/clang.gni` 和 `build/cross-build.sh` 硬编码了 `/opt/` 路径）。

构建前先将工具链复制到 `/opt/`：

```bash
sudo cp -r chromium-full-src-150.0.7871.211-linux-la64/opt/. /opt/
```

然后运行 patch 中包含的构建脚本：

```bash
export RUSTC_BOOTSTRAP=1
cd chromium-full-src-150.0.7871.211-linux-la64/src
./build/cross-build.sh la64
autoninja -C out/la64_cross chrome
```

### deepin v25/UOS v25 构建问题

1. 交叉编译 loong64 架构 Chromium，出现如下错误：

```
python3 /work/Downloads/chromium-full-src-126.0.6478.182-linux-loong64/src/build/config/linux/pkg-config.py -s /work/Downloads/chromium-full-src-126.0.6478.182-linux-loong64/src/build/linux/debian_bullseye_loongarch64-sysroot -a loong64 xkbcommon
Traceback (most recent call last):
File "/work/Downloads/chromium-full-src-126.0.6478.182-linux-loong64/src/build/config/linux/pkg-config.py", line 247, in <module>
sys.exit(main())
^^^^^^
File "/work/Downloads/chromium-full-src-126.0.6478.182-linux-loong64/src/build/config/linux/pkg-config.py", line 142, in main
prefix = GetPkgConfigPrefixToStrip(options, args)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
File "/work/Downloads/chromium-full-src-126.0.6478.182-linux-loong64/src/build/config/linux/pkg-config.py", line 80, in GetPkgConfigPrefixToStrip
prefix = subprocess.check_output([options.pkg_config,
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
File "/usr/lib/python3.12/subprocess.py", line 466, in check_output
return run(*popenargs, stdout=PIPE, timeout=timeout, check=True,
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
File "/usr/lib/python3.12/subprocess.py", line 571, in run
raise CalledProcessError(retcode, process.args,
subprocess.CalledProcessError: Command '['pkg-config', '--variable=prefix', 'xkbcommon']' returned non-zero exit status 1.
```

解决方案：

修改 src/build/config/linux/pkg-config.py 脚本的 SetConfigPath(options) 函数，增加一行：

```
libdir += ':' + sysroot + '/usr/lib64/pkgconfig'
```

2. 出现如下错误：

```
[6782/9308] ACTION //tools/v8_context_snapshot:generate_v8_context_snapshot(//build/toolchain/linux:clang_x64_v8_loong64)
FAILED: v8_context_snapshot.bin 
python3 ../../build/gn_run_binary.py ./clang_x64_v8_loong64/v8_context_snapshot_generator --output_file=v8_context_snapshot.bin
././clang_x64_v8_loong64/v8_context_snapshot_generator: error while loading shared libraries: libffi.so.7: cannot open shared object file: No such file or directory
./clang_x64_v8_loong64/v8_context_snapshot_generator failed with exit code 127
```

解决方案：从源码编译 `libffi-3.3`（对应 soname libffi.so.7）

```
wget https://github.com/libffi/libffi/releases/download/v3.3/libffi-3.3.tar.gz
tar -xf libffi-3.3.tar.gz
cd libffi-3.3
./configure --prefix=/usr/local/libffi7
make -j$(nproc)
sudo make install
# 添加到动态链接器
echo "/usr/local/libffi7/lib" | sudo tee /etc/ld.so.conf.d/libffi7.conf
sudo ldconfig
ldconfig -p | grep libffi.so.7
```

3. 编译 blink 时出现错误：

```
gen/third_party/blink/renderer/platform/color_data.cc:242:7: error: fallthrough annotation does not directly precede switch label
  242 |       [[fallthrough]];
      |       ^
```

解决方案：修改 src/third_party/blink/renderer/build/scripts/gperf.py 脚本，将

```
gperf_output = gperf_output.replace('/*FALLTHROUGH*/',
                                            '  [[fallthrough]];')
``

这两行注释掉。

## 项目与 Chromium 的关系

本项目：

* 不属于 Chromium 官方项目；
* 不维护 Chromium fork；
* 不重新发布 Chromium 的 Git 历史；
* 主要负责 Chromium 源码及构建依赖的归档和分发。

Chromium 源码及其中包含的第三方组件分别遵循其各自的许可证和版权声明。

使用、修改和再分发源码时，请遵循 Chromium 及相关第三方组件的 LICENSE、NOTICE 和其他许可证要求。

## License

本项目自身的脚本和配置文件按照仓库中的 LICENSE 发布。

Chromium 源码以及其中包含的第三方组件不属于本项目原创内容，其许可证以源码中的 LICENSE、NOTICE 以及各第三方组件自身的许可证文件为准。
