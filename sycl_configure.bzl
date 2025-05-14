"""Repository rule for SYCL autoconfiguration.
`sycl_configure` depends on the following environment variables:
  * `TF_NEED_SYCL`: Whether to enable building with SYCL.
  * `GCC_HOST_COMPILER_PATH`: The GCC host compiler path
"""

load(
    "//third_party/remote_config:common.bzl",
    "err_out",
    "execute",
    "files_exist",
    "get_bash_bin",
    "get_host_environ",
    "get_python_bin",
    "raw_exec",
    "realpath",
    "which",
)
load(
    ":compiler_common_tools.bzl",
    "to_list_of_strings",
)
load(
    ":cuda_configure.bzl",
    "make_copy_dir_rule",
    "make_copy_files_rule",
)

load(
    "//third_party/gpus/sycl:sycl_dl_essential.bzl",
    "sycl_redist",
)

load(
    ":cuda_configure.bzl",
    "enable_cuda",
)


_GCC_HOST_COMPILER_PATH = "GCC_HOST_COMPILER_PATH"
_GCC_HOST_COMPILER_PREFIX = "GCC_HOST_COMPILER_PREFIX"
_CLANG_HOST_COMPILER_PATH = "CLANG_COMPILER_PATH"
_CLANG_HOST_COMPILER_PREFIX = "CLANG_HOST_COMPILER_PATH"

def _mkl_include_path(sycl_config):
    return sycl_config.mkl_include_dir

def _mkl_library_path(sycl_config):
    return sycl_config.mkl_library_dir

def _l0_include_path(sycl_config):
    return sycl_config.l0_include_dir

def _l0_library_path(sycl_config):
    return sycl_config.l0_library_dir

def _sycl_header_path(repository_ctx, sycl_config, bash_bin):
    sycl_header_path = sycl_config.sycl_toolkit_path
    include_dir = sycl_header_path + "/include"
    if not files_exist(repository_ctx, [include_dir], bash_bin)[0]:
        sycl_header_path = sycl_header_path + "/linux"
        include_dir = sycl_header_path + "/include"
        if not files_exist(repository_ctx, [include_dir], bash_bin)[0]:
            auto_configure_fail("Cannot find sycl headers in {}".format(include_dir))
    return sycl_header_path

def _sycl_include_path(repository_ctx, sycl_config, bash_bin):
    """Generates the cxx_builtin_include_directory entries for sycl inc dirs.

    Args:
      repository_ctx: The repository context.
      sycl_config: The path to the gcc host compiler.

    Returns:
      A string containing the Starlark string for each of the gcc
      host compiler include directories, which can be added to the CROSSTOOL
      file.
    """
    inc_dirs = []

    inc_dirs.append(_mkl_include_path(sycl_config))
    inc_dirs.append(_sycl_header_path(repository_ctx, sycl_config, bash_bin) + "/include")
    inc_dirs.append(_sycl_header_path(repository_ctx, sycl_config, bash_bin) + "/include/sycl")

    return inc_dirs

def enable_sycl(repository_ctx):
    if "TF_NEED_SYCL" in repository_ctx.os.environ:
        enable_sycl = repository_ctx.os.environ["TF_NEED_SYCL"].strip()
        return enable_sycl == "1"
    return False
def _flag_enabled(repository_ctx, flag_name):
    if flag_name in repository_ctx.os.environ:
        flag_value = repository_ctx.os.environ[flag_name].strip()
        return flag_value == "1"
    return False

def _use_icx(repository_ctx):
    # Returns the flag if we need to use ICX both for C++ and SYCL.
    return _flag_enabled(repository_ctx, "TF_ICX")

def _use_icx_and_clang(repository_ctx):
    # Returns the flag if we need to use clang for C++ and ICX for SYCL.
    return _flag_enabled(repository_ctx, "TF_ICX_CLANG")

def auto_configure_fail(msg):
    """Output failure message when auto configuration fails."""
    red = "\033[0;31m"
    no_color = "\033[0m"
    fail("\n%sAuto-Configuration Error:%s %s\n" % (red, no_color, msg))

def find_cc(repository_ctx):
    """Find the C++ compiler."""

    # Return a dummy value for GCC detection here to avoid error
    if _use_icx_and_clang(repository_ctx):
      target_cc_name = "clang"
      cc_path_envvar = _CLANG_HOST_COMPILER_PATH
    else:
      target_cc_name = "gcc"
      cc_path_envvar = _GCC_HOST_COMPILER_PATH
    cc_name = target_cc_name
    cc_name_from_env = get_host_environ(repository_ctx, cc_path_envvar)
    if cc_name_from_env:
        cc_name = cc_name_from_env
    if cc_name.startswith("/"):
        # Absolute path, maybe we should make this supported by our which function.
        return cc_name
    cc = which(repository_ctx, cc_name)
    if cc == None:
        fail(("Cannot find {}, either correct your path or set the {}" +
              " environment variable").format(target_cc_name, cc_path_envvar))
    return cc

def find_sycl_root(repository_ctx, sycl_config):
    sycl_name = str(repository_ctx.path(sycl_config.sycl_toolkit_path.strip()).realpath)
    if sycl_name.startswith("/"):
        return sycl_name
    fail("Cannot find DPC++ compiler, please correct your path")

def find_sycl_include_path(repository_ctx, sycl_config):
    """Find DPC++ compiler."""
    base_path = find_sycl_root(repository_ctx, sycl_config)
    bin_path = repository_ctx.path(base_path + "/" + "bin" + "/" + "icpx")
    icpx_extra = ""
    if not bin_path.exists:
        bin_path = repository_ctx.path(base_path + "/" + "bin" + "/" + "clang")
        if not bin_path.exists:
            fail("Cannot find DPC++ compiler, please correct your path")
    else:
        icpx_extra = "-fsycl"
    gcc_path = repository_ctx.which("gcc")
    gcc_install_dir = repository_ctx.execute([gcc_path, "-print-libgcc-file-name"])
    gcc_install_dir_opt = "--gcc-install-dir=" + str(repository_ctx.path(gcc_install_dir.stdout.strip()).dirname)
    
    clang_path = repository_ctx.which("clang")
    clang_install_dir = repository_ctx.execute([clang_path, "-print-resource-dir"])
    clang_install_dir_opt = "--sysroot=" + str(repository_ctx.path(clang_install_dir.stdout.strip()).dirname)
    cmd_out = repository_ctx.execute([bin_path, icpx_extra, gcc_install_dir_opt, clang_install_dir_opt, "-xc++", "-E", "-v", "/dev/null", "-o", "/dev/null"])

    outlist = cmd_out.stderr.split("\n")
    real_base_path = str(repository_ctx.path(base_path).realpath).strip()
    include_dirs = []
    for l in outlist:
        if l.startswith(" ") and l.strip().startswith("/") and str(repository_ctx.path(l.strip()).realpath) not in include_dirs:
            include_dirs.append(str(repository_ctx.path(l.strip()).realpath))
    return include_dirs

def _lib_name(lib, version = "", static = False):
    """Constructs the name of a library on Linux.

    Args:
      lib: The name of the library, such as "hip"
      version: The version of the library.
      static: True the library is static or False if it is a shared object.

    Returns:
      The platform-specific name of the library.
    """
    if static:
        return "lib%s.a" % lib
    else:
        if version:
            version = ".%s" % version
        return "lib%s.so%s" % (lib, version)

def _sycl_lib_paths(repository_ctx, lib, basedir):
    """
    Purpose: Returns a list with the full path to a shared library (lib<name>.so) in a given directory.

    Input:
        lib: The library name (e.g., mkl_core).
        basedir: The directory to look in.

    Output:
        A list containing a single path: basedir/lib<lib>.so.
    """
    file_name = _lib_name(lib, version="", static=False)
    return [
        repository_ctx.path("%s/%s" % (basedir, file_name)),
    ]


def _batch_files_exist(repository_ctx, libs_paths, bash_bin):
    """
    Purpose: Checks which of the library paths actually exist.

    Input:
        libs_paths: A list of tuples (lib_name, [paths]).

    Output:
        A list of booleans indicating whether each file exists.
    """
    all_paths = []
    for _, lib_paths in libs_paths:
        for lib_path in lib_paths:
            all_paths.append(lib_path)
    return files_exist(repository_ctx, all_paths, bash_bin)


def _select_sycl_lib_paths(repository_ctx, libs_paths, bash_bin):
    """
    Purpose: Picks the first existing path for each library.

    Logic:
        Iterates through all possible paths for each library.
        If no path exists for a given library, it throws an error.
        For successful matches, it constructs a struct.

    Returns:
        A dict mapping library name to its resolved path and filename.
    """
    test_results = _batch_files_exist(repository_ctx, libs_paths, bash_bin)

    libs = {}
    i = 0
    for name, lib_paths in libs_paths:
        selected_path = None
        for path in lib_paths:
            if test_results[i] and selected_path == None:
                # For each lib, select the first path that exists.
                selected_path = path
            i += 1
        if selected_path == None:
            auto_configure_fail("Cannot find sycl library %s in %s" % (name, path))

        libs[name] = struct(
            file_name=selected_path.basename,
            path=realpath(repository_ctx, selected_path, bash_bin)
        )

    return libs

def _find_libs(repository_ctx, sycl_config, bash_bin):
    """
    Returns the SYCL libraries on the system.

    Args:
        repository_ctx: The repository context.
        sycl_config: The SYCL config as returned by _get_sycl_config
        bash_bin: The path to the bash interpreter

    Returns:
        Map of library names to structs of filename and path.
        Example:
        {
            "mkl_intel_ilp64": struct(
                file_name = "libmkl_intel_ilp64.so",
                path = "/opt/intel/oneapi/mkl/2024.0.0/lib/libmkl_intel_ilp64.so"
            ),
            ...
        }
    """
    mkl_path = _mkl_library_path(sycl_config)
    libs_paths = [
        (name, _sycl_lib_paths(repository_ctx, name, mkl_path))
        for name in ["mkl_intel_ilp64", "mkl_sequential", "mkl_core"]
    ]

    if sycl_config.sycl_basekit_version_number < "2024":
        libs_paths.append(("mkl_sycl", _sycl_lib_paths(repository_ctx, "mkl_sycl", mkl_path)))
    else:
        libs_paths.extend([
            ("mkl_sycl_blas", _sycl_lib_paths(repository_ctx, "mkl_sycl_blas", mkl_path)),
            ("mkl_sycl_lapack", _sycl_lib_paths(repository_ctx, "mkl_sycl_lapack", mkl_path)),
            ("mkl_sycl_sparse", _sycl_lib_paths(repository_ctx, "mkl_sycl_sparse", mkl_path)),
            ("mkl_sycl_dft", _sycl_lib_paths(repository_ctx, "mkl_sycl_dft", mkl_path)),
            ("mkl_sycl_vm", _sycl_lib_paths(repository_ctx, "mkl_sycl_vm", mkl_path)),
            ("mkl_sycl_rng", _sycl_lib_paths(repository_ctx, "mkl_sycl_rng", mkl_path)),
            ("mkl_sycl_stats", _sycl_lib_paths(repository_ctx, "mkl_sycl_stats", mkl_path)),
            ("mkl_sycl_data_fitting", _sycl_lib_paths(repository_ctx, "mkl_sycl_data_fitting", mkl_path)),
        ])

    l0_path = _l0_library_path(sycl_config)
    libs_paths.append(("ze_loader", _sycl_lib_paths(repository_ctx, "ze_loader", l0_path)))

    return _select_sycl_lib_paths(repository_ctx, libs_paths, bash_bin)


def find_sycl_config(repository_ctx):
    """
    Returns SYCL config dictionary from running find_sycl_config.py.
    """
    python_bin = get_python_bin(repository_ctx)
    exec_result = execute(repository_ctx, [python_bin, repository_ctx.attr._find_sycl_config])
    if exec_result.return_code:
        auto_configure_fail("Failed to run find_sycl_config.py: %s" % err_out(exec_result))

    # Parse the dict from stdout.
    return dict([tuple(x.split(": ")) for x in exec_result.stdout.splitlines()])


def _get_sycl_config(repository_ctx, bash_bin):
    """Detects and returns information about the SYCL installation on the system.

    Args:
      repository_ctx: The repository context.
      bash_bin: the path to the path interpreter
    """
    config = find_sycl_config(repository_ctx)
    sycl_basekit_path = config["sycl_basekit_path"]
    sycl_toolkit_path = config["sycl_toolkit_path"]
    sycl_version_number = config["sycl_version_number"]
    sycl_basekit_version_number = config["sycl_basekit_version_number"]
    mkl_include_dir = config["mkl_include_dir"]
    mkl_library_dir = config["mkl_library_dir"]
    l0_include_dir = config["l0_include_dir"]
    l0_library_dir = config["l0_library_dir"]
    return struct(
        sycl_basekit_path = sycl_basekit_path,
        sycl_toolkit_path = sycl_toolkit_path,
        sycl_version_number = sycl_version_number,
        sycl_basekit_version_number = sycl_basekit_version_number,
        mkl_include_dir = mkl_include_dir,
        mkl_library_dir = mkl_library_dir,
        l0_include_dir = l0_include_dir,
        l0_library_dir = l0_library_dir,
    )

def _tpl_path(repository_ctx, labelname):
    return repository_ctx.path(Label("//third_party/gpus/%s.tpl" % labelname))

def _tpl(repository_ctx, tpl, substitutions = {}, out = None):
    if not out:
        out = tpl.replace(":", "/")
    repository_ctx.template(
        out,
        _tpl_path(repository_ctx, tpl),
        substitutions,
    )

_INC_DIR_MARKER_BEGIN = "#include <...>"

def _cxx_inc_convert(path):
    """Convert path returned by cc -E xc++ in a complete path."""
    path = path.strip()
    return path

def _normalize_include_path(repository_ctx, path):
    """Normalizes include paths before writing them to the crosstool.

      If path points inside the 'crosstool' folder of the repository, a relative
      path is returned.
      If path points outside the 'crosstool' folder, an absolute path is returned.
      """
    path = str(repository_ctx.path(path))
    crosstool_folder = str(repository_ctx.path(".").get_child("crosstool"))

    if path.startswith(crosstool_folder):
        # We drop the path to "$REPO/crosstool" and a trailing path separator.
        return "\"" + path[len(crosstool_folder) + 1:] + "\""
    return "\"" + path + "\""

def _get_cxx_inc_directories_impl(repository_ctx, cc, lang_is_cpp):
    """Compute the list of default C or C++ include directories."""
    if lang_is_cpp:
        lang = "c++"
    else:
        lang = "c"

    result = raw_exec(repository_ctx, [
        cc,
        "-no-canonical-prefixes",
        "-E",
        "-x" + lang,
        "-",
        "-v",
    ])
    stderr = err_out(result)
    index1 = stderr.find(_INC_DIR_MARKER_BEGIN)
    if index1 == -1:
        return []
    index1 = stderr.find("\n", index1)
    if index1 == -1:
        return []
    index2 = stderr.rfind("\n ")
    if index2 == -1 or index2 < index1:
        return []
    index2 = stderr.find("\n", index2 + 1)
    if index2 == -1:
        inc_dirs = stderr[index1 + 1:]
    else:
        inc_dirs = stderr[index1 + 1:index2].strip()

    return [
        str(repository_ctx.path(_cxx_inc_convert(p)))
        for p in inc_dirs.split("\n")
    ]

def get_cxx_inc_directories(repository_ctx, cc):
    """Compute the list of default C and C++ include directories."""

    # For some reason `clang -xc` sometimes returns include paths that are
    # different from the ones from `clang -xc++`. (Symlink and a dir)
    # So we run the compiler with both `-xc` and `-xc++` and merge resulting lists
    includes_cpp = _get_cxx_inc_directories_impl(repository_ctx, cc, True)
    includes_c = _get_cxx_inc_directories_impl(repository_ctx, cc, False)

    includes_cpp_set = depset(includes_cpp)
    return includes_cpp + [
        inc
        for inc in includes_c
        if inc not in includes_cpp_set.to_list()
    ]

_DUMMY_CROSSTOOL_BZL_FILE = """
def error_gpu_disabled():
  fail("ERROR: Building with --config=sycl but TensorFlow is not configured " +
       "to build with GPU support. Please re-run ./configure and enter 'Y' " +
       "at the prompt to build with GPU support.")

  native.genrule(
      name = "error_gen_crosstool",
      outs = ["CROSSTOOL"],
      cmd = "echo 'Should not be run.' && exit 1",
  )

  native.filegroup(
      name = "crosstool",
      srcs = [":CROSSTOOL"],
      output_licenses = ["unencumbered"],
  )
"""

_DUMMY_CROSSTOOL_BUILD_FILE = """
load("//crosstool:error_gpu_disabled.bzl", "error_gpu_disabled")

error_gpu_disabled()
"""

def _create_dummy_repository(repository_ctx):
    # Set up BUILD file for sycl/.
    _tpl(repository_ctx, "sycl:build_defs.bzl")
    _tpl(repository_ctx, "sycl:BUILD")

    # If sycl_configure is not configured to build with SYCL support, and the user
    # attempts to build with --config=sycl, add a dummy build rule to intercept
    # this and fail with an actionable error message.
    repository_ctx.file(
        "crosstool/error_gpu_disabled.bzl",
        _DUMMY_CROSSTOOL_BZL_FILE,
    )
    repository_ctx.file("crosstool/BUILD", _DUMMY_CROSSTOOL_BUILD_FILE)

    _tpl(
        repository_ctx,
        "sycl:build_defs.bzl",
        {
            "%{sycl_is_configured}": "False",
            "%{sycl_build_is_configured}": "False",
        },
    )
def _extract_file_name_from_url(url):
    """Extract the file name from a URL by finding the last slash '/'."""
    return url[url.rfind("/") + 1:]


def _download_and_extract_archive(ctx, package_info): 
    """Downloads and installs the archive or .sh installer."""
    archive_filename = _extract_file_name_from_url(package_info.url)
    temp_directory = "tmp"
    _DISTRIBUTION_PATH = "sycl_toolchain"

    ctx.file(temp_directory + "/.idx")  # Marker to ensure directory exists

    ctx.report_progress(
        "Downloading and processing {}, expected hash is {}".format(
            package_info.url, package_info.sha256
        )
    )  # buildifier: disable=print

    if package_info.url.endswith(".sh"):
        # Handle Intel offline installer shell script
        ctx.download(
            url = package_info.url,
            output = archive_filename,
            sha256 = package_info.sha256,
        )

        ctx.execute([
            "bash", archive_filename,
            "-a", "--silent", "--eula", "accept",
            "--install-dir", _DISTRIBUTION_PATH + "/sycl_dl_essentials",
        ])
        ctx.delete(archive_filename)

    elif package_info.url.endswith(".deb"):
        # Download and extract .deb into temp, then extract data.tar.*
        ctx.download_and_extract(
            url = package_info.url,
            output = temp_directory,
            sha256 = package_info.sha256,
        )
        temp_files = ctx.path(temp_directory).readdir()
        data_archives = [
            entry for entry in temp_files
            if _extract_file_name_from_url(str(entry)).startswith("data.")
        ]
        for archive in data_archives:
            ctx.extract(archive, _DISTRIBUTION_PATH)
        ctx.delete(temp_directory)

    else:
        # Standard archive extraction (e.g. .tar.gz, .zip)
        ctx.download_and_extract(
            url = package_info.url,
            output = _DISTRIBUTION_PATH,
            sha256 = package_info.sha256,
        )


def _strip_root_directory(file_path, base_dir):
    """Removes the base directory prefix from the given path if present."""
    if file_path.startswith(base_dir + "/"):
        return file_path[len(base_dir) + 1:]
    return file_path


_OS = "OS"
_SYCL_VERSION = "sycl_basekit_version_number"
_SYCL_TOOLKIT_PATH = "SYCL_TOOLKIT_PATH"
_DEFAULT_SYCL_TOOLKIT_PATH = "/opt/intel/oneapi/compiler/latest"
_DISTRIBUTION_PATH = "sycl_toolchain"

def _generate_sycl_config(ctx, bash_executable, host_path, container_path):
    """Generates a SYCL config struct based on the hermetic distribution layout."""
    sycl_version_number = ctx.os.environ.get(_SYCL_VERSION, "2025.1.0")
    
    return struct(
        sycl_toolkit_path = host_path + "/compiler/{}/linux".format(sycl_version_number),
        sycl_basekit_path = host_path,
        sycl_version_number = sycl_version_number,
        sycl_basekit_version_number = sycl_version_number,
        mkl_include_dir = host_path + "/mkl/latest/include",
        mkl_library_dir = host_path + "/mkl/latest/lib/intel64",
        l0_include_dir = host_path + "/compiler/{}/linux/include/level_zero".format(sycl_version_number),
        l0_library_dir = host_path + "/compiler/{}/linux/lib".format(sycl_version_number),
    )


def _initialize_sycl_distribution(ctx):
    """Prepares the SYCL distribution directory for hermetic builds."""
    bash_executable = get_bash_bin(ctx)
    current_os = ctx.os.environ.get(_OS)
    sycl_version = ctx.os.environ.get(_SYCL_VERSION)

    if not current_os:
        ctx.fail("Error: '_OS' environment variable not set.")
    if not sycl_version:
        ctx.fail("Error: '_SYCL_VERSION' environment variable not set.")

    if current_os and sycl_version:
        distribution_data = sycl_redist[current_os][sycl_version]
        ctx.file("sycl/.index")

        for package in distribution_data["archives"]:
            _download_and_extract_archive(ctx, package)

        return _generate_sycl_config(
            ctx,
            bash_executable,
            "{}/{}".format(_DISTRIBUTION_PATH, distribution_data["sycl_root"]),
            "/{}".format(distribution_data["sycl_root"]),
        )
    else:
        sycl_toolkit_path = ctx.os.environ.get(_SYCL_TOOLKIT_PATH, _DEFAULT_SYCL_TOOLKIT_PATH)
        ctx.report_progress(
            "Using local SYCL installation {}".format(sycl_toolkit_path)
        )  # buildifier: disable=print
        ctx.symlink(sycl_toolkit_path, _DISTRIBUTION_PATH)
        return _generate_sycl_config(
            ctx, bash_executable, _DISTRIBUTION_PATH, _DEFAULT_SYCL_TOOLKIT_PATH
        )




def _create_local_sycl_repository(repository_ctx):
    tpl_paths = {
        labelname: _tpl_path(repository_ctx, labelname)
        for labelname in [
            "sycl:build_defs.bzl",
            "sycl:BUILD",
            "crosstool:BUILD.sycl",
            "crosstool:sycl_cc_toolchain_config.bzl",
            "crosstool:clang/bin/crosstool_wrapper_driver_sycl",
            "crosstool:clang/bin/ar_driver",
            "sycl:sycl_config.h",
        ]
    }

    bash_bin = get_bash_bin(repository_ctx)
    sycl_config = _get_sycl_config(repository_ctx, bash_bin)

    # Copy headers
    copy_rules = [
        make_copy_dir_rule(
            repository_ctx,
            name="sycl-include",
            src_dir=_sycl_header_path(repository_ctx, sycl_config, bash_bin) + "/include",
            out_dir="sycl/include",
        ),
        make_copy_dir_rule(
            repository_ctx,
            name="mkl-include",
            src_dir=_mkl_include_path(sycl_config),
            out_dir="sycl/include",
        ),
        make_copy_dir_rule(
            repository_ctx,
            name="level-zero-include",
            src_dir=_l0_include_path(sycl_config),
            out_dir="level_zero/include/level_zero",
        ),
    ]

    # Copy libraries
    sycl_libs = _find_libs(repository_ctx, sycl_config, bash_bin)
    sycl_lib_srcs = [lib.path for lib in sycl_libs.values()]
    sycl_lib_outs = ["sycl/lib/" + lib.file_name for lib in sycl_libs.values()]
    copy_rules.append(make_copy_files_rule(
        repository_ctx,
        name="sycl-lib",
        srcs=sycl_lib_srcs,
        outs=sycl_lib_outs,
    ))

    # Generate build_defs.bzl
    repository_ctx.template(
        "sycl/build_defs.bzl",
        tpl_paths["sycl:build_defs.bzl"],
        {
            "%{sycl_is_configured}": "True",
            "%{sycl_build_is_configured}": "True",
        },
    )

    # Generate mkl_sycl_libs
    if sycl_config.sycl_basekit_version_number < "2024":
        mkl_sycl_libs = '"sycl/lib/{}"'.format(sycl_libs["mkl_sycl"].file_name)
    else:
        mkl_sycl_keys = [
            "mkl_sycl_blas", "mkl_sycl_lapack", "mkl_sycl_sparse", "mkl_sycl_dft",
            "mkl_sycl_vm", "mkl_sycl_rng", "mkl_sycl_stats", "mkl_sycl_data_fitting",
        ]
        mkl_sycl_libs = ",\n".join([
                    '"sycl/lib/{}"'.format(sycl_libs[k].file_name) for k in mkl_sycl_keys
        ])

    level_zero_libs = '"sycl/lib/{}"'.format(sycl_libs["ze_loader"].file_name)

    repository_ctx.template(
        "sycl/BUILD",
        tpl_paths["sycl:BUILD"],
        {
            "%{mkl_intel_ilp64_lib}": sycl_libs["mkl_intel_ilp64"].file_name,
            "%{mkl_sequential_lib}": sycl_libs["mkl_sequential"].file_name,
            "%{mkl_core_lib}": sycl_libs["mkl_core"].file_name,
            "%{mkl_sycl_libs}": mkl_sycl_libs,
            "%{copy_rules}": "\n".join(copy_rules),
            "%{sycl_headers}": '":mkl-include",\n":sycl-include"',
            "%{level_zero_libs}": level_zero_libs,
            "%{level_zero_headers}": '":level-zero-include"',
        },
    )

    # Crosstool setup
    is_icx_and_clang = _use_icx_and_clang(repository_ctx)
    cc = find_cc(repository_ctx)
    clang_host_prefix = get_host_environ(repository_ctx, _CLANG_HOST_COMPILER_PREFIX, "/usr/bin")
    gcc_host_prefix = get_host_environ(repository_ctx, _GCC_HOST_COMPILER_PREFIX, "/usr/bin")

    sycl_defines = {
        "%{host_compiler_path}": "clang/bin/crosstool_wrapper_driver_sycl",
        "%{extra_no_canonical_prefixes_flags}": (
            "\"-no-canonical-prefixes\"" if is_icx_and_clang else "\"-fno-canonical-system-headers\""
        ),
        "%{host_compiler_prefix}": clang_host_prefix if is_icx_and_clang else gcc_host_prefix,
        "%{ar_path}": "clang/bin/ar_driver",
        "%{cpu_compiler}": str(cc),
        "%{linker_bin_path}": "/usr/bin",
        "%{sycl_compiler_root}": str(sycl_config.sycl_toolkit_path),
        "%{SYCL_ROOT_DIR}": str(sycl_config.sycl_toolkit_path),
        "%{basekit_path}": str(sycl_config.sycl_basekit_path),
        "%{basekit_version}": str(sycl_config.sycl_basekit_version_number),
        "%{tf_icx_clang}": str(is_icx_and_clang),
    }

    host_includes = get_cxx_inc_directories(repository_ctx, cc)
    builtin_includes = find_sycl_include_path(repository_ctx, sycl_config)
    toolkit_includes = _sycl_include_path(repository_ctx, sycl_config, bash_bin)

    sycl_defines["%{cxx_builtin_include_directories}"] = to_list_of_strings(
        builtin_includes + toolkit_includes + host_includes
    )

    sycl_defines["%{unfiltered_compile_flags}"] = to_list_of_strings([
        "-DTENSORFLOW_USE_SYCL=1",
        "-DMKL_ILP64",
        "-fPIC",
        "-fsycl",
    ])
    sycl_defines["%{sycl_build_is_configured}"] = "1"  # Or "0" if not hermetic

    # Crosstool templates
    repository_ctx.template(
        "crosstool/BUILD",
        tpl_paths["crosstool:BUILD.sycl"],
        sycl_defines,
    )
    repository_ctx.template(
        "crosstool/cc_toolchain_config.bzl",
        tpl_paths["crosstool:sycl_cc_toolchain_config.bzl"],
        sycl_defines,
    )
    repository_ctx.template(
        "crosstool/clang/bin/crosstool_wrapper_driver_sycl",
        tpl_paths["crosstool:clang/bin/crosstool_wrapper_driver_sycl"],
        sycl_defines,
    )
    repository_ctx.template(
        "crosstool/clang/bin/ar_driver",
        tpl_paths["crosstool:clang/bin/ar_driver"],
        sycl_defines,
    )

    # SYCL config headers
    repository_ctx.template(
        "sycl/sycl_config/sycl_config.h",
        tpl_paths["sycl:sycl_config.h"],
        sycl_defines,
    )
    repository_ctx.template(
        "sycl/sycl_config_hermetic/sycl_config.h",
        tpl_paths["sycl:sycl_config.h"],
        sycl_defines,
    )


def _sycl_autoconf_imp(repository_ctx):
    """Implementation of the sycl_autoconf rule."""
    if not enable_sycl(repository_ctx):
        _create_dummy_repository(repository_ctx)
    else:
        _create_local_sycl_repository(repository_ctx)

sycl_configure = repository_rule(
    implementation = _sycl_autoconf_imp,
    local = True,
    attrs = {
        "_find_sycl_config": attr.label(
            default = Label("//third_party/gpus:find_sycl_config.py"),
        ),
    },
)
"""Detects and configures the local SYCL toolchain.

Add the following to your WORKSPACE FILE:

```python
sycl_configure(name = "local_config_sycl")
```

Args:
  name: A unique name for this workspace rule.
"""
