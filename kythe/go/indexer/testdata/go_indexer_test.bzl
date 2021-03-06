#
# Copyright 2016 The Kythe Authors. All rights reserved.
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

# Bazel rules to extract Go compilations from library targets for testing the
# Go cross-reference indexer.
load(
    "@io_bazel_rules_go//go:def.bzl",
    "GoSource",
    "go_library",
)
load(
    "//tools/build_rules/verifier_test:verifier_test.bzl",
    "KytheEntries",
    "kythe_integration_test",
    "verifier_test",
)

# Emit a shell script that sets up the environment needed by the extractor to
# capture dependencies and runs the extractor.
def _emit_extractor_script(ctx, mode, script, output, srcs, deps, ipath, data):
    tmpdir = output.dirname + "/tmp"
    srcdir = tmpdir + "/src/" + ipath
    pkgdir = tmpdir + "/pkg/%s_%s" % (mode.goos, mode.goarch)
    extras = []
    cmds = ["#!/bin/sh -e", "mkdir -p " + pkgdir, "mkdir -p " + srcdir]

    # Link the source files and dependencies into a common temporary directory.
    # Source files need to be made relative to the temp directory.
    ups = srcdir.count("/") + 1
    cmds += [
        'ln -s "%s%s" "%s"' % ("../" * ups, src.path, srcdir)
        for src in srcs
    ]
    for path, dpath in deps.items():
        fullpath = "/".join([pkgdir, dpath])
        tups = fullpath.count("/")
        cmds += [
            "mkdir -p " + fullpath.rsplit("/", 1)[0],
            "ln -s '%s%s' '%s.a'" % ("../" * tups, path, fullpath),
        ]

    # Gather any extra data dependencies.
    for target in data:
        for f in target.files.to_list():
            cmds.append('ln -s "%s%s" "%s"' % ("../" * ups, f.path, srcdir))
            extras.append(srcdir + "/" + f.path.rsplit("/", 1)[-1])

    # Invoke the extractor on the temp directory.
    goroot = "/".join(ctx.files._sdk_files[0].path.split("/")[:-2])
    cmds.append("export GOCACHE=\"$PWD/" + tmpdir + "/cache\"")
    cmds.append("export CGO_ENABLED=0")
    cmds.append(" ".join([
        ctx.files._extractor[-1].path,
        "-output",
        output.path,
        "-goroot",
        goroot,
        "-gopath",
        tmpdir,
        "-extra_files",
        "'%s'" % ",".join(extras),
        ipath,
    ]))

    f = ctx.actions.declare_file(script)
    ctx.actions.write(output = f, content = "\n".join(cmds), is_executable = True)
    return f

def _go_extract(ctx):
    gosrc = ctx.attr.library[GoSource]
    mode = gosrc.mode
    srcs = gosrc.srcs
    deps = {}  # TODO(schroederc): support dependencies
    ipath = gosrc.library.importpath
    data = ctx.attr.data
    output = ctx.outputs.kzip
    script = _emit_extractor_script(
        ctx,
        mode,
        ctx.label.name + "-extract.sh",
        output,
        srcs,
        deps,
        ipath,
        data,
    )

    extras = []
    for target in data:
        extras += target.files.to_list()

    tools = ctx.files._extractor + ctx.files._sdk_files
    ctx.actions.run(
        mnemonic = "GoExtract",
        executable = script,
        outputs = [output],
        inputs = srcs + extras,
        tools = tools,
    )
    return struct(kzip = output)

# Generate a kzip with the compilations captured from a single Go library or
# binary rule.
go_extract = rule(
    _go_extract,
    attrs = {
        # Additional data files to include in each compilation.
        "data": attr.label_list(
            allow_empty = True,
            allow_files = True,
        ),
        "library": attr.label(
            providers = [GoSource],
            mandatory = True,
        ),
        "_extractor": attr.label(
            default = Label("//kythe/go/extractors/cmd/gotool"),
            executable = True,
            cfg = "host",
        ),
        "_sdk_files": attr.label(
            allow_files = True,
            default = "@go_sdk//:files",
        ),
    },
    outputs = {"kzip": "%{name}.kzip"},
    toolchains = ["@io_bazel_rules_go//go:toolchain"],
)

def _go_entries(ctx):
    kzip = ctx.attr.kzip.kzip
    indexer = ctx.files._indexer[-1]
    iargs = [indexer.path]
    output = ctx.outputs.entries

    # If the test wants marked source, enable support for it in the indexer.
    if ctx.attr.has_marked_source:
        iargs.append("-code")

    # If the test wants linkage metadata, enable support for it in the indexer.
    if ctx.attr.metadata_suffix:
        iargs += ["-meta", ctx.attr.metadata_suffix]

    iargs += [kzip.path, "| gzip >" + output.path]

    cmds = ["set -e", "set -o pipefail", " ".join(iargs), ""]
    ctx.actions.run_shell(
        mnemonic = "GoIndexer",
        command = "\n".join(cmds),
        outputs = [output],
        inputs = [kzip],
        tools = [ctx.executable._indexer],
    )
    return [KytheEntries(compressed = depset([output]), files = depset())]

# Run the Kythe indexer on the output that results from a go_extract rule.
go_entries = rule(
    _go_entries,
    attrs = {
        # Whether to enable explosion of MarkedSource facts.
        "has_marked_source": attr.bool(default = False),

        # The go_extract output to pass to the indexer.
        "kzip": attr.label(
            providers = ["kzip"],
            mandatory = True,
        ),

        # The suffix used to recognize linkage metadata files, if non-empty.
        "metadata_suffix": attr.string(default = ""),

        # The location of the Go indexer binary.
        "_indexer": attr.label(
            default = Label("//kythe/go/indexer/cmd/go_indexer"),
            executable = True,
            cfg = "host",
        ),
    },
    outputs = {"entries": "%{name}.entries.gz"},
)

def go_verifier_test(
        name,
        entries,
        size = "small",
        tags = [],
        log_entries = False,
        has_marked_source = False,
        allow_duplicates = False):
    opts = ["--use_file_nodes", "--show_goals", "--check_for_singletons"]
    if log_entries:
        opts.append("--show_protos")
    if allow_duplicates:
        opts.append("--ignore_dups")

    # If the test wants marked source, enable support for it in the verifier.
    if has_marked_source:
        opts.append("--convert_marked_source")
    return verifier_test(
        name = name,
        size = size,
        opts = opts,
        tags = tags,
        deps = [entries],
    )

# Shared extract/index logic for the go_indexer_test/go_integration_test rules.
def _go_indexer(
        name,
        srcs,
        deps = [],
        importpath = None,
        data = None,
        has_marked_source = False,
        allow_duplicates = False,
        metadata_suffix = ""):
    if len(deps) > 0:
        # TODO(schroederc): support dependencies
        fail("ERROR: go_indexer_test.deps not supported")
    if importpath == None:
        importpath = native.package_name() + "/" + name
    lib = name + "_lib"
    go_library(
        name = lib,
        srcs = srcs,
        importpath = importpath,
        deps = deps,
    )
    kzip = name + "_units"
    go_extract(
        name = kzip,
        data = data,
        library = lib,
    )
    entries = name + "_entries"
    go_entries(
        name = entries,
        has_marked_source = has_marked_source,
        kzip = ":" + kzip,
        metadata_suffix = metadata_suffix,
    )
    return entries

# A convenience macro to generate a test library, pass it to the Go indexer,
# and feed the output of indexing to the Kythe schema verifier.
def go_indexer_test(
        name,
        srcs,
        deps = [],
        import_path = None,
        size = None,
        tags = None,
        log_entries = False,
        data = None,
        has_marked_source = False,
        allow_duplicates = False,
        metadata_suffix = ""):
    entries = _go_indexer(
        name = name,
        srcs = srcs,
        data = data,
        has_marked_source = has_marked_source,
        importpath = import_path,
        metadata_suffix = metadata_suffix,
        deps = deps,
    )
    go_verifier_test(
        name = name,
        size = size,
        allow_duplicates = allow_duplicates,
        entries = ":" + entries,
        has_marked_source = has_marked_source,
        log_entries = log_entries,
        tags = tags,
    )

# A convenience macro to generate a test library, pass it to the Go indexer,
# and feed the output of indexing to the Kythe integration test pipeline.
def go_integration_test(
        name,
        srcs,
        deps = [],
        data = None,
        file_tickets = [],
        import_path = None,
        size = "small",
        has_marked_source = False,
        metadata_suffix = ""):
    entries = _go_indexer(
        name = name,
        srcs = srcs,
        data = data,
        has_marked_source = has_marked_source,
        import_path = import_path,
        metadata_suffix = metadata_suffix,
        deps = deps,
    )
    kythe_integration_test(
        name = name,
        size = size,
        srcs = [":" + entries],
        file_tickets = file_tickets,
    )
