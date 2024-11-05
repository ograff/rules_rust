# Copyright 2018 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Rules for performing `rustdoc --test` on Bazel built crates"""

load("//rust/private:common.bzl", "rust_common")
load("//rust/private:providers.bzl", "CrateInfo")
load("//rust/private:rustdoc.bzl", "rustdoc_compile_action")
load("//rust/private:utils.bzl", "dedent", "find_toolchain", "transform_deps", "determine_output_hash")

def _format_arg(file):
    return file.short_path

def _rust_doc_test_impl(ctx):
    """The implementation of the `rust_test` rule.

    Args:
        ctx (ctx): The ctx object for the current target.

    Returns:
        list: The list of providers. See `rustc_compile_action`
    """
    toolchain = find_toolchain(ctx)

    crate_type = "bin"
    deps = transform_deps(ctx.attr.deps)
    crate = ctx.attr.crate[rust_common.crate_info]

    crate_name = crate.name
    output_hash = determine_output_hash(crate.root, ctx.label)
    output = ctx.actions.declare_directory(
        "test_bins-%s/%s%s" % (
            output_hash,
            ctx.label.name,
            toolchain.binary_ext,
        ),
    )

    # Build the test binary using the dependency's srcs.
    crate_info = rust_common.create_crate_info(
        name = crate_name,
        type = crate_type,
        root = crate.root,
        srcs = crate.srcs,
        deps = depset(deps, transitive = [crate.deps]),
        proc_macro_deps = crate.proc_macro_deps,
        aliases = crate.aliases,
        output = crate.output,
        edition = crate.edition,
        rustc_env = crate.rustc_env,
        rustc_env_files = crate.rustc_env_files,
        is_test = True,
        compile_data = crate.compile_data,
        compile_data_targets = crate.compile_data_targets,
        wrapped_crate_type = crate.type,
        owner = ctx.label,
    )

    rustdoc_flags = [
        "--extern",
        "{}={}".format(crate_info.name, crate_info.output.path),
        "--test",
        "-Z",
        "unstable-options",
        "--no-run",
        "--persist-doctests",
        output.path,
    ]


    action = rustdoc_compile_action(
        ctx = ctx,
        toolchain = toolchain,
        crate_info = crate_info,
        rustdoc_flags = rustdoc_flags,
        is_test = True,
    )

    ctx.actions.run(
        mnemonic = "RustDocTest",
        progress_message = "Compiling Rustdoc test for {}".format(ctx.attr.crate.label),
        executable = ctx.executable._process_wrapper,
        inputs = action.inputs,
        outputs = [output],
        tools = action.tools,
        arguments = action.arguments,
        env = action.env,
    )

    runner_args = ctx.actions.args()
    runner_args.add_all([output], map_each=_format_arg)
    files_out = ctx.actions.declare_file(ctx.label.name + ".files")
    ctx.actions.write(output = files_out, content = runner_args)

    runner_out = ctx.actions.declare_file(ctx.label.name + ".run")
    ctx.actions.run_shell(outputs = [runner_out], command = """
echo "#!/bin/bash" >> {1}
echo "set -xe" >> {1}
cat {0} >> {1}
chmod +x {1}
""".format(files_out.path, runner_out.path), inputs=[files_out])

    providers = [DefaultInfo(
        executable = runner_out,
        runfiles = ctx.runfiles(files=[output])
    )]

    env = action.env
    if toolchain.llvm_cov and ctx.configuration.coverage_enabled:
        if not toolchain.llvm_profdata:
            fail("toolchain.llvm_profdata is required if toolchain.llvm_cov is set.")

        if toolchain._experimental_use_coverage_metadata_files:
            llvm_cov_path = toolchain.llvm_cov.path
            llvm_profdata_path = toolchain.llvm_profdata.path
        else:
            llvm_cov_path = toolchain.llvm_cov.short_path
            if llvm_cov_path.startswith("../"):
                llvm_cov_path = llvm_cov_path[len("../"):]

            llvm_profdata_path = toolchain.llvm_profdata.short_path
            if llvm_profdata_path.startswith("../"):
                llvm_profdata_path = llvm_profdata_path[len("../"):]

        env["RUST_LLVM_COV"] = llvm_cov_path
        env["RUST_LLVM_PROFDATA"] = llvm_profdata_path
    components = "{}/{}".format(ctx.label.workspace_root, ctx.label.package).split("/")
    env["CARGO_MANIFEST_DIR"] = "/".join([c for c in components if c])
    providers.append(RunEnvironmentInfo(
        environment = env,
        inherited_environment = [],
    ))

    return providers

rust_doc_test = rule(
    implementation = _rust_doc_test_impl,
    attrs = {
        "crate": attr.label(
            doc = (
                "The label of the target to generate code documentation for. " +
                "`rust_doc_test` can generate HTML code documentation for the " +
                "source files of `rust_library` or `rust_binary` targets."
            ),
            providers = [rust_common.crate_info],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = dedent("""\
                List of other libraries to be linked to this library target.

                These can be either other `rust_library` targets or `cc_library` targets if
                linking a native library.
            """),
            providers = [[CrateInfo], [CcInfo]],
        ),
        "_cc_toolchain": attr.label(
            doc = (
                "In order to use find_cc_toolchain, your rule has to depend " +
                "on C++ toolchain. See @rules_cc//cc:find_cc_toolchain.bzl " +
                "docs for details."
            ),
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
        "_process_wrapper": attr.label(
            doc = "A process wrapper for running rustdoc on all platforms",
            cfg = "exec",
            default = Label("//util/process_wrapper"),
            executable = True,
        ),
    },
    test = True,
    fragments = ["cpp"],
    toolchains = [
        str(Label("//rust:toolchain_type")),
        "@bazel_tools//tools/cpp:toolchain_type",
    ],
    doc = dedent("""\
        Runs Rust documentation tests.

        Example:

        Suppose you have the following directory structure for a Rust library crate:

        ```output
        [workspace]/
        WORKSPACE
        hello_lib/
            BUILD
            src/
                lib.rs
        ```

        To run [documentation tests][doc-test] for the `hello_lib` crate, define a `rust_doc_test` \
        target that depends on the `hello_lib` `rust_library` target:

        [doc-test]: https://doc.rust-lang.org/book/documentation.html#documentation-as-tests

        ```python
        package(default_visibility = ["//visibility:public"])

        load("@rules_rust//rust:defs.bzl", "rust_library", "rust_doc_test")

        rust_library(
            name = "hello_lib",
            srcs = ["src/lib.rs"],
        )

        rust_doc_test(
            name = "hello_lib_doc_test",
            crate = ":hello_lib",
        )
        ```

        Running `bazel test //hello_lib:hello_lib_doc_test` will run all documentation tests for the `hello_lib` library crate.
    """),
)
