#
# Copyright 2017 The Kythe Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

load(
    "@bazel_tools//tools/build_defs/cc:action_names.bzl",
    "CPP_COMPILE_ACTION_NAME",
)
load("@bazel_skylib//lib:paths.bzl", "paths")
load(":toolchain_utils.bzl", "find_cpp_toolchain")
load(
    ":verifier_test.bzl",
    "KytheEntries",
    "KytheVerifierSources",
    "extract",
    "verifier_test",
)

UNSUPPORTED_FEATURES = [
    "thin_lto",
    "module_maps",
    "use_header_modules",
    "fdo_instrument",
    "fdo_optimize",
]

CxxCompilationUnits = provider(
    doc = "A bundle of pre-extracted Kythe CompilationUnits for C++.",
    fields = {
        "files": "Depset of .kzip files.",
    },
)

_VERIFIER_FLAGS = {
    "check_for_singletons": False,
    "convert_marked_source": False,
    "goal_prefix": "//-",
    "ignore_dups": False,
}

_INDEXER_FLAGS = {
    "experimental_alias_template_instantiations": False,
    "experimental_drop_cpp_fwd_decl_docs": False,
    "experimental_drop_instantiation_independent_data": False,
    "experimental_drop_objc_fwd_class_docs": False,
    "experimental_usr_byte_size": 0,
    "fail_on_unimplemented_builtin": True,
    "ignore_unimplemented": False,
    "index_template_instantiations": True,
    "ibuild_config": "",
}

def _compiler_options(ctx, cc_toolchain, copts, includes, cc_info):
    """Returns the list of compiler flags from the C++ toolchain."""
    feature_configuration = cc_common.configure_features(
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features + UNSUPPORTED_FEATURES,
    )
    variables = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        user_compile_flags = copts,
        include_directories = cc_info.compilation_context.includes,
        quote_include_directories = cc_info.compilation_context.quote_includes,
        system_include_directories = depset(direct = includes, transitive = [cc_info.compilation_context.system_includes]),
        add_legacy_cxx_options = True,
    )

    # TODO(schroederc): use memory-efficient Args, when available
    args = ctx.actions.args()
    args.add_all(cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = CPP_COMPILE_ACTION_NAME,
        variables = variables,
    ))
    return args

def _flag(name, typename, value):
    if value == None:  # Omit None flags.
        return None

    if type(value) != typename:
        fail("Invalid value for %s: %s; expected %s, found %s" % (
            name,
            value,
            typename,
            type(value),
        ))
    if typename == "bool":
        value = str(value).lower()
    return "--%s=%s" % (name, value)

def _flags(values, defaults):
    return [
        flag
        for flag in [
            _flag(name, type(default), values.pop(name, default))
            for name, default in defaults.items()
        ]
        if flag != None
    ]

def _split_flags(kwargs):
    flags = struct(
        indexer = _flags(kwargs, _INDEXER_FLAGS),
        verifier = _flags(kwargs, _VERIFIER_FLAGS),
    )
    if kwargs:
        fail("Unrecognized verifier flags: %s" % (kwargs.keys(),))
    return flags

def _transitive_entries(deps):
    files, compressed = [], []
    for dep in deps:
        if KytheEntries in dep:
            files += dep[KytheEntries].files
            compressed += dep[KytheEntries].compressed
    return KytheEntries(compressed = depset(transitive = compressed), files = depset(transitive = files))

def _generate_files(ctx, files, extension):
    return [
        ctx.actions.declare_file(
            paths.replace_extension(
                paths.relativize(f.path, ctx.label.package),
                extension,
            ),
        )
        for f in files
    ]

def _format_path_and_short_path(f):
    return "-I{0}={1}".format(f.short_path, f.path)

def _get_short_path(f):
    return f.short_path

_KytheProtoInfo = provider()

def _cc_kythe_proto_library_aspect_impl(target, ctx):
    sources = _generate_files(ctx, target[ProtoInfo].direct_sources, ".pb.cc")
    headers = _generate_files(ctx, target[ProtoInfo].direct_sources, ".pb.h")
    args = ctx.actions.args()
    args.add("--plugin=protoc-gen-PLUGIN=" + ctx.executable._plugin.path)
    args.add("--PLUGIN_out=:" + ctx.bin_dir.path + "/")
    args.add_all(target[ProtoInfo].transitive_sources, map_each = _format_path_and_short_path)
    args.add_all(target[ProtoInfo].direct_sources, map_each = _get_short_path)
    ctx.actions.run(
        arguments = [args],
        outputs = sources + headers,
        inputs = target[ProtoInfo].transitive_sources,
        executable = ctx.executable._protoc,
        tools = [ctx.executable._plugin],
        mnemonic = "GenerateKytheCCProto",
    )
    cc_toolchain = find_cpp_toolchain(ctx)
    cc_info_providers = [lib[CcInfo] for lib in [target, ctx.attr._runtime] if CcInfo in lib]
    feature_configuration = cc_common.configure_features(
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features + UNSUPPORTED_FEATURES,
    )
    compile_protos_cc_info = cc_common.compile(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        srcs = sources,
        hdrs = headers,
        feature_configuration = feature_configuration,
        compilation_contexts = [provider.compilation_context for provider in cc_info_providers],
    )
    linking_info = cc_common.link(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        cc_compilation_outputs = compile_protos_cc_info.cc_compilation_outputs,
        feature_configuration = feature_configuration,
        linking_contexts = [provider.linking_context for provider in cc_info_providers],
    )
    return [
        _KytheProtoInfo(files = depset(sources + headers)),
        CcInfo(
            compilation_context = compile_protos_cc_info.compilation_context,
            linking_context = linking_info.linking_context,
        ),
    ]

_cc_kythe_proto_library_aspect = aspect(
    attr_aspects = ["deps"],
    attrs = {
        "_protoc": attr.label(
            default = Label("@com_google_protobuf//:protoc"),
            executable = True,
            cfg = "host",
        ),
        "_plugin": attr.label(
            default = Label("//kythe/cxx/tools:proto_metadata_plugin"),
            executable = True,
            cfg = "host",
        ),
        "_runtime": attr.label(
            default = Label("@com_google_protobuf//:protobuf"),
            cfg = "target",
        ),
        # Do not add references, temporary attribute for find_cpp_toolchain.
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    fragments = ["cpp"],
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
    implementation = _cc_kythe_proto_library_aspect_impl,
)

def _cc_kythe_proto_library(ctx):
    return [
        ctx.attr.deps[0][CcInfo],
        DefaultInfo(files = ctx.attr.deps[0][_KytheProtoInfo].files),
    ]

cc_kythe_proto_library = rule(
    attrs = {
        "deps": attr.label_list(
            providers = [ProtoInfo],
            aspects = [_cc_kythe_proto_library_aspect],
        ),
    },
    implementation = _cc_kythe_proto_library,
)

def _cc_extract_kzip_impl(ctx):
    cpp = find_cpp_toolchain(ctx)
    if cpp.libc == "macosx":
        toolchain_includes = cpp.built_in_include_directories
    else:
        toolchain_includes = []
    cc_info = cc_common.merge_cc_infos(cc_infos = [
        src[CcInfo]
        for src in ctx.attr.srcs + ctx.attr.deps
        if CcInfo in src
    ])
    outputs = depset([
        extract(
            srcs = depset([src]),
            ctx = ctx,
            extractor = ctx.executable.extractor,
            kzip = ctx.actions.declare_file("{}/{}.kzip".format(ctx.label.name, src.basename)),
            opts = _compiler_options(
                ctx,
                cpp,
                ctx.attr.opts,
                toolchain_includes,
                cc_info,
            ),
            vnames_config = ctx.file.vnames_config,
            deps = depset(
                direct = ctx.files.srcs,
                transitive = [depset(ctx.files.deps), cc_info.compilation_context.headers],
            ),
        )
        for src in ctx.files.srcs
        if not src.path.endswith(".h")  # Don't extract headers.
    ])
    for dep in ctx.attr.deps:
        if CxxCompilationUnits in dep:
            outputs += dep[CxxCompilationUnits].files
    return [
        DefaultInfo(files = outputs),
        CxxCompilationUnits(files = outputs),
        KytheVerifierSources(files = depset(ctx.files.srcs)),
        _transitive_entries(ctx.attr.deps),
    ]

cc_extract_kzip = rule(
    attrs = {
        "srcs": attr.label_list(
            doc = "A list of C++ source files to extract.",
            mandatory = True,
            allow_empty = False,
            allow_files = [
                ".cc",
                ".c",
                ".h",
            ],
        ),
        "copts": attr.string_list(
            doc = """Options which are required to compile/index the sources.

            These will be included in the resulting .kzip CompilationUnits.
            """,
        ),
        "extractor": attr.label(
            default = Label("//kythe/cxx/extractor:cxx_extractor"),
            executable = True,
            cfg = "host",
        ),
        "opts": attr.string_list(
            doc = "Options which will be passed to the extractor as arguments.",
        ),
        "vnames_config": attr.label(
            doc = "vnames_config file to be used by the extractor.",
            default = Label("//external:vnames_config"),
            allow_single_file = [".json"],
        ),
        "deps": attr.label_list(
            doc = """Files which are required by the extracted sources.

            Additionally, targets providing KytheEntries or CxxCompilationUnits
            may be used for dependencies which are required for an eventual
            Kythe index, but should not be extracted here.
            """,
            allow_files = [
                ".cc",
                ".c",
                ".h",
                ".meta",  # Cross language metadata files.
            ],
            providers = [
                [CcInfo],
                [KytheEntries],
                [CxxCompilationUnits],
            ],
        ),
        # Do not add references, temporary attribute for find_cpp_toolchain.
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    doc = """cc_extract_kzip extracts srcs into CompilationUnits.

    Each file in srcs will be extracted into a separate .kzip file, based on the name
    of the source.
    """,
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
    implementation = _cc_extract_kzip_impl,
)

def _extract_bundle_impl(ctx):
    bundle = ctx.actions.declare_directory(ctx.label.name + "_unbundled")
    ctx.actions.run(
        inputs = [ctx.file.src],
        tools = [ctx.executable.unbundle],
        outputs = [bundle],
        mnemonic = "Unbundle",
        executable = ctx.executable.unbundle,
        arguments = [ctx.file.src.path, bundle.path],
    )
    ctx.actions.run_shell(
        inputs = [
            ctx.file.vnames_config,
            bundle,
        ],
        tools = [ctx.executable.extractor],
        outputs = [ctx.outputs.kzip],
        mnemonic = "ExtractBundle",
        env = {
            "KYTHE_OUTPUT_FILE": ctx.outputs.kzip.path,
            "KYTHE_ROOT_DIRECTORY": ".",
            "KYTHE_VNAMES": ctx.file.vnames_config.path,
        },
        arguments = [
            ctx.executable.extractor.path,
            bundle.path,
        ] + ctx.attr.opts,
        command = "\"$1\" -c \"${@:2}\" $(cat \"${2}/cflags\") \"${2}/test_bundle/test.cc\"",
    )

    # TODO(shahms): Allow directly specifying the unbundled sources as verifier sources,
    #   rather than relying on --use_file_nodes.
    #   Possibly, just use the bundled source directly as the verifier doesn't actually
    #   care about the expanded source.
    #   Bazel makes it hard to use a glob here.
    return [CxxCompilationUnits(files = depset([ctx.outputs.kzip]))]

cc_extract_bundle = rule(
    attrs = {
        "src": attr.label(
            doc = "Label of the bundled test to extract.",
            mandatory = True,
            allow_single_file = True,
        ),
        "extractor": attr.label(
            default = Label("//kythe/cxx/extractor:cxx_extractor"),
            executable = True,
            cfg = "host",
        ),
        "opts": attr.string_list(
            doc = "Additional arguments to pass to the extractor.",
        ),
        "unbundle": attr.label(
            default = Label("//tools/build_rules/verifier_test:unbundle"),
            executable = True,
            cfg = "host",
        ),
        "vnames_config": attr.label(
            default = Label("//kythe/cxx/indexer/cxx/testdata:test_vnames.json"),
            allow_single_file = True,
        ),
    },
    doc = "Extracts a bundled C++ indexer test into a .kzip file.",
    outputs = {"kzip": "%{name}.kzip"},
    implementation = _extract_bundle_impl,
)

def _bazel_extract_kzip_impl(ctx):
    # TODO(shahms): This is a hack as we get both executable
    #   and .sh from files.scripts but only want the "executable" one.
    #   Unlike `attr.label`, `attr.label_list` lacks an `executable` argument.
    #   Excluding "is_source" files may be overly aggressive, but effective.
    scripts = [s for s in ctx.files.scripts if not s.is_source]
    ctx.actions.run(
        inputs = [
            ctx.file.vnames_config,
            ctx.file.data,
        ] + scripts + ctx.files.srcs,
        tools = [ctx.executable.extractor],
        outputs = [ctx.outputs.kzip],
        mnemonic = "BazelExtractKZip",
        executable = ctx.executable.extractor,
        arguments = [
            ctx.file.data.path,
            ctx.outputs.kzip.path,
            ctx.file.vnames_config.path,
        ] + [script.path for script in scripts],
    )
    return [
        KytheVerifierSources(files = depset(ctx.files.srcs)),
        CxxCompilationUnits(files = depset([ctx.outputs.kzip])),
    ]

# TODO(shahms): Clean up the bazel extraction rules.
_bazel_extract_kzip = rule(
    attrs = {
        "srcs": attr.label_list(
            doc = "Source files to provide via KytheVerifierSources.",
            allow_files = True,
        ),
        "data": attr.label(
            doc = "The .xa extra action to extract.",
            # TODO(shahms): This should be the "src" which is extracted.
            mandatory = True,
            allow_single_file = [".xa"],
        ),
        "extractor": attr.label(
            default = Label("//kythe/cxx/extractor:cxx_extractor_bazel"),
            executable = True,
            cfg = "host",
        ),
        "scripts": attr.label_list(
            cfg = "host",
            allow_files = True,
        ),
        "vnames_config": attr.label(
            default = Label("//external:vnames_config"),
            allow_single_file = True,
        ),
    },
    doc = "Extracts a Bazel extra action binary proto file into a .kzip.",
    outputs = {"kzip": "%{name}.kzip"},
    implementation = _bazel_extract_kzip_impl,
)

def _cc_index_source(ctx, src):
    entries = ctx.actions.declare_file(
        ctx.label.name + "/" + src.basename + ".entries",
    )
    ctx.actions.run(
        mnemonic = "CcIndexSource",
        outputs = [entries],
        inputs = ctx.files.srcs + ctx.files.deps,
        tools = [ctx.executable.indexer],
        executable = ctx.executable.indexer,
        arguments = [ctx.expand_location(o) for o in ctx.attr.opts] + [
            "-i",
            src.path,
            "-o",
            entries.path,
            "--",
            "-c",
        ] + [ctx.expand_location(o) for o in ctx.attr.copts],
    )
    return entries

def _cc_index_compilation(ctx, compilation):
    if ctx.attr.copts:
        print("Ignoring compiler options:", ctx.attr.copts)
    entries = ctx.actions.declare_file(
        ctx.label.name + "/" + compilation.basename + ".entries",
    )
    ctx.actions.run(
        mnemonic = "CcIndexCompilation",
        outputs = [entries],
        inputs = [compilation],
        tools = [ctx.executable.indexer],
        executable = ctx.executable.indexer,
        arguments = [ctx.expand_location(o) for o in ctx.attr.opts] + [
            "-o",
            entries.path,
            compilation.path,
        ],
    )
    return entries

def _cc_index_single_file(ctx, input):
    if input.extension == "kzip":
        return _cc_index_compilation(ctx, input)
    elif input.extension in ("c", "cc", "m"):
        return _cc_index_source(ctx, input)
    fail("Cannot index input file: %s" % (input,))

def _cc_index_impl(ctx):
    intermediates = [
        _cc_index_single_file(ctx, src)
        for src in ctx.files.srcs
        if src.extension in ("m", "c", "cc", "kzip")
    ]
    intermediates += [
        _cc_index_compilation(ctx, kzip)
        for dep in ctx.attr.deps
        if CxxCompilationUnits in dep
        for kzip in dep[CxxCompilationUnits].files
        if kzip not in ctx.files.deps
    ]

    entries = depset(intermediates)
    for dep in ctx.attr.deps:
        if KytheEntries in dep:
            entries += dep[KytheEntries].files

    ctx.actions.run_shell(
        outputs = [ctx.outputs.entries],
        inputs = entries,
        command = '("${@:1:${#@}-1}" || rm -f "${@:${#@}}") | gzip -c > "${@:${#@}}"',
        mnemonic = "CompressEntries",
        arguments = ["cat"] + [i.path for i in entries.to_list()] + [ctx.outputs.entries.path],
    )

    sources = [depset([src for src in ctx.files.srcs if src.extension != "kzip"])]
    for dep in ctx.attr.srcs:
        if KytheVerifierSources in dep:
            sources += [dep[KytheVerifierSources].files]
    return [
        KytheVerifierSources(files = depset(transitive = sources)),
        KytheEntries(compressed = depset([ctx.outputs.entries]), files = entries),
    ]

# TODO(shahms): Support cc_library deps, along with cc toolchain support.
# TODO(shahms): Split objc_index into a separate rule.
cc_index = rule(
    attrs = {
        # .cc/.h files, added to KytheVerifierSources provider, but not transitively.
        # CxxCompilationUnits, which may also include sources.
        "srcs": attr.label_list(
            doc = "C++/ObjC source files or extracted .kzip files to index.",
            allow_files = [
                ".cc",
                ".c",
                ".h",
                ".m",  # Objective-C is supported by the indexer as well.
                ".kzip",
            ],
            providers = [CxxCompilationUnits],
        ),
        "copts": attr.string_list(
            doc = "Options to pass to the compiler while indexing.",
        ),
        "indexer": attr.label(
            default = Label("//kythe/cxx/indexer/cxx:indexer"),
            executable = True,
            cfg = "host",
        ),
        "opts": attr.string_list(
            doc = "Options to pass to the indexer.",
        ),
        "deps": attr.label_list(
            doc = "Files required to index srcs or entries to include in the index.",
            # .meta files, .h files, .entries{,.gz}, KytheEntries
            allow_files = [
                ".h",
                ".entries",
                ".entries.gz",
                ".meta",  # Cross language metadata files.
            ],
            providers = [KytheEntries],
        ),
    },
    doc = """Produces a Kythe index from the C++ source files.

    Files in `srcs` and `deps` will be indexed, files in `srcs` will
    additionally be included in the provided KytheVerifierSources.
    KytheEntries dependencies will be transitively included in the index.
    """,
    outputs = {
        "entries": "%{name}.entries.gz",
    },
    implementation = _cc_index_impl,
)

def _indexer_test(
        name,
        srcs,
        copts,
        deps = [],
        tags = [],
        size = "small",
        restricted_to = ["//buildenv:all"],
        bundled = False,
        expect_fail_verify = False,
        indexer = None,
        **kwargs):
    flags = _split_flags(kwargs)
    if bundled:
        if len(srcs) != 1:
            fail("Bundled indexer tests require exactly one src!")
        cc_extract_bundle(
            name = name + "_kzip",
            testonly = True,
            src = srcs[0],
            opts = copts,
            restricted_to = restricted_to,
            tags = tags,
        )
        srcs = [":" + name + "_kzip"]
    cc_index(
        name = name + "_entries",
        testonly = True,
        srcs = srcs,
        copts = copts if not bundled else [],
        indexer = indexer,
        opts = (["-claim_unknown=false"] if bundled else []) + flags.indexer,
        restricted_to = restricted_to,
        tags = tags,
        deps = deps,
    )
    verifier_test(
        name = name,
        size = size,
        # TODO(shahms): Use sources directly?
        srcs = [":" + name + "_entries"],
        expect_success = not expect_fail_verify,
        opts = flags.verifier,
        restricted_to = restricted_to,
        tags = tags,
    )

# If a test is expected to pass on darwin but not on linux, you can set
# restricted_to=["//buildenv:darwin"]. This causes the test to be skipped on linux and it
# causes the actual test to execute on darwin.
def cc_indexer_test(
        name,
        srcs,
        deps = [],
        tags = [],
        size = "small",
        restricted_to = ["//buildenv:all"],
        std = "c++11",
        bundled = False,
        expect_fail_verify = False,
        indexer = "//kythe/cxx/indexer/cxx:indexer",
        copts = [],
        **kwargs):
    """C++ indexer test rule.

    Args:
      name: The name of the test rule.
      srcs: Source files to index and run the verifier.
      deps: Sources, compilation units or entries which should be present
        in the index or are required to index the sources.
      std: The C++ standard to use for the test.
      bundled: True if this test is a "bundled" C++ test and must be extracted.
      expect_fail_verify: True if this test is expected to fail.
      convert_marked_source: Whether the verifier should convert marked source.
      ignore_dups: Whether the verifier should ignore duplicate nodes.
      check_for_singletons: Whether the verifier should check for singleton facts.
      goal_prefix: The comment prefix the verifier should use for goals.
      fail_on_unimplemented_builtin: Whether the indexer should fail on
        unimplemented builtins.
      ignore_unimplemented: Whether the indexer should continue after encountering
        an unimplemented construct.
      index_template_instantiations: Whether the indexer should index template
        instantiations.
      experimental_alias_template_instantiations: Whether the indexer should alias
        template instantiations.
      experimental_drop_instantiation_independent_data: Whether the indexer should
        drop extraneous instantiation independent data.
      experimental_usr_byte_size: How many bytes of a USR to use.
    """
    _indexer_test(
        name = name,
        srcs = srcs,
        deps = deps,
        tags = tags,
        size = size,
        copts = ["-std=" + std] + copts,
        restricted_to = restricted_to,
        bundled = bundled,
        expect_fail_verify = expect_fail_verify,
        indexer = indexer,
        **kwargs
    )

def objc_indexer_test(
        name,
        srcs,
        deps = [],
        tags = [],
        size = "small",
        restricted_to = ["//buildenv:all"],
        bundled = False,
        expect_fail_verify = False,
        indexer = "//kythe/cxx/indexer/cxx:indexer",
        **kwargs):
    """Objective C indexer test rule.

    Args:
      name: The name of the test rule.
      srcs: Source files to index and run the verifier.
      deps: Sources, compilation units or entries which should be present
        in the index or are required to index the sources.
      bundled: True if this test is a "bundled" C++ test and must be extracted.
      expect_fail_verify: True if this test is expected to fail.
      convert_marked_source: Whether the verifier should convert marked source.
      ignore_dups: Whether the verifier should ignore duplicate nodes.
      check_for_singletons: Whether the verifier should check for singleton facts.
      goal_prefix: The comment prefix the verifier should use for goals.
      fail_on_unimplemented_builtin: Whether the indexer should fail on
        unimplemented builtins.
      ignore_unimplemented: Whether the indexer should continue after encountering
        an unimplemented construct.
      index_template_instantiations: Whether the indexer should index template
        instantiations.
      experimental_alias_template_instantiations: Whether the indexer should alias
        template instantiations.
      experimental_drop_instantiation_independent_data: Whether the indexer should
        drop extraneous instantiation independent data.
      experimental_usr_byte_size: How many bytes of a USR to use.
    """
    _indexer_test(
        name = name,
        srcs = srcs,
        deps = deps,
        tags = tags,
        size = size,
        copts = ["-fblocks"],
        restricted_to = restricted_to,
        bundled = bundled,
        expect_fail_verify = expect_fail_verify,
        indexer = indexer,
        **kwargs
    )

def objc_bazel_extractor_test(name, src, data, size = "small", tags = [], restricted_to = ["//buildenv:all"]):
    """Objective C Bazel extractor test.

    Args:
      src: The source file to use with the verifier.
      data: The extracted .xa protocol buffer to index.
    """
    _bazel_extract_kzip(
        name = name + "_kzip",
        testonly = True,
        srcs = [src],
        data = data,
        extractor = "//kythe/cxx/extractor:objc_extractor_bazel",
        restricted_to = restricted_to,
        scripts = [
            "//third_party/bazel:get_devdir",
            "//third_party/bazel:get_sdkroot",
        ],
        tags = tags,
    )
    cc_index(
        name = name + "_entries",
        testonly = True,
        srcs = [":" + name + "_kzip"],
        restricted_to = restricted_to,
        tags = tags,
    )
    return verifier_test(
        name = name,
        size = size,
        srcs = [":" + name + "_entries"],
        opts = ["--ignore_dups"],
        restricted_to = restricted_to,
        tags = tags,
    )

def cc_bazel_extractor_test(name, src, data, size = "small", tags = []):
    """C++ Bazel extractor test.

    Args:
      src: The source file to use with the verifier.
      data: The extracted .xa protocol buffer to index.
    """
    _bazel_extract_kzip(
        name = name + "_kzip",
        testonly = True,
        srcs = [src],
        data = data,
        tags = tags,
    )
    cc_index(
        name = name + "_entries",
        testonly = True,
        srcs = [":" + name + "_kzip"],
        tags = tags,
    )
    return verifier_test(
        name = name,
        size = size,
        srcs = [":" + name + "_entries"],
        opts = ["--ignore_dups"],
        tags = tags,
    )

def cc_extractor_test(
        name,
        srcs,
        deps = [],
        data = [],
        size = "small",
        std = "c++11",
        tags = [],
        restricted_to = ["//buildenv:all"]):
    """C++ verifier test on an extracted source file."""
    args = ["-std=" + std, "-c"]
    cc_extract_kzip(
        name = name + "_kzip",
        testonly = True,
        srcs = srcs,
        opts = args,
        restricted_to = restricted_to,
        tags = tags,
        deps = data,
    )
    cc_index(
        name = name + "_entries",
        testonly = True,
        srcs = [":" + name + "_kzip"],
        opts = ["--ignore_unimplemented"],
        restricted_to = restricted_to,
        tags = tags,
        deps = data,
    )
    return verifier_test(
        name = name,
        size = size,
        srcs = [":" + name + "_entries"],
        opts = ["--ignore_dups"],
        restricted_to = restricted_to,
        tags = tags,
        deps = deps,
    )
