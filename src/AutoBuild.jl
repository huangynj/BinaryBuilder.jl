export autobuild, print_buildjl

"""
    autobuild(dir::AbstractString, src_name::AbstractString, platforms::Vector,
              sources::Vector, script, products)

Runs the boiler plate code to download, build, and package a source package
for multiple platforms.  `src_name`
"""
function autobuild(dir::AbstractString, src_name::AbstractString,
                   platforms::Vector, sources::Vector, script, products;
                   dependencies::Vector = AbstractDependency[],
                   verbose::Bool = true)
    # If we're on Travis and we're not verbose, schedule a task to output a "." every few seconds
    if haskey(ENV, "TRAVIS") && !verbose
        run_travis_busytask = true
        travis_busytask = @async begin
            # Don't let Travis think we're asleep...
            info("Brewing a pot of coffee for Travis...")
            while run_travis_busytask
                sleep(4)
                print(".")
            end
        end
    end

    # First, download the source(s), store in ./downloads/
    downloads_dir = joinpath(dir, "downloads")
    try mkpath(downloads_dir) end
    for idx in 1:length(sources)
        src_url, src_hash = sources[idx]
        if endswith(src_url, ".git")
            src_path = joinpath(downloads_dir, basename(src_url))
            if !isdir(src_path)
                repo = LibGit2.clone(src_url, src_path; isbare=true)
            else
                LibGit2.with(LibGit2.GitRepo(src_path)) do repo
                    LibGit2.fetch(repo)
                end
            end
        else
            if isfile(src_url)
                # Immediately abspath() a src_url so we don't lose track of
                # sources given to us with a relative path
                src_path = abspath(src_url)

                # And if this is a locally-sourced tarball, just verify
                verify(src_path, src_hash; verbose=verbose)
            else
                # Otherwise, download and verify
                src_path = joinpath(downloads_dir, basename(src_url))
                download_verify(src_url, src_hash, src_path; verbose=verbose)
            end
        end
        sources[idx] = (src_path => src_hash)
    end

    # Our build products will go into ./products
    out_path = joinpath(dir, "products")
    try mkpath(out_path) end
    product_hashes = Dict()

    for platform in platforms
        target = triplet(platform)

        # We build in a platform-specific directory
        build_path = joinpath(pwd(), "build", target)
        try mkpath(build_path) end

        cd(build_path) do
            src_paths, src_hashes = collect(zip(sources...))

            # Convert from tuples to arrays, if need be
            src_paths = collect(src_paths)
            src_hashes = collect(src_hashes)
            prefix, ur = setup_workspace(build_path, src_paths, src_hashes, dependencies, platform; verbose=true)

            # Don't keep the downloads directory around
            rm(joinpath(prefix, "downloads"); force=true, recursive=true)

            dep = Dependency(src_name, products(prefix), script, platform, prefix)
            if !build(ur, dep; verbose=verbose, autofix=true)
                error("Failed to build $(target)")
            end

            # Remove the files of any dependencies
            for dependency in dependencies
                dep_script = script_for_dep(dependency)
                m = Module(:__anon__)
                eval(m, quote
                    using BinaryProvider
                    platform_key() = $platform
                    macro write_deps_file(args...); end
                    function install(url, hash;
                        prefix::Prefix = BinaryProvider.global_prefix,
                        kwargs...)
                        manifest_path = BinaryProvider.manifest_from_url(url; prefix=prefix)
                        BinaryProvider.uninstall(manifest_path; verbose=$verbose)
                    end
                    ARGS = [$(prefix.path)]
                    include_string($(dep_script))
                end)
            end

            # Once we're built up, go ahead and package this prefix out
            tarball_path, tarball_hash = package(prefix, joinpath(out_path, src_name); platform=platform, verbose=verbose, force=true)
            product_hashes[target] = (basename(tarball_path), tarball_hash)
        end

        # Finally, destroy the build_path
        rm(build_path; recursive=true)
    end

    if haskey(ENV, "TRAVIS") && !verbose
        run_travis_busytask = false
        wait(travis_busytask)
        println()
    end

    # Finally, print out our awesome build.jl
    print_buildjl(product_hashes)
end

function print_buildjl(product_hashes::Dict)
    info("Use this as your deps/build.jl template:")
    print("""
    using BinaryProvider

    # This is where all binaries will get installed
    const prefix = Prefix(joinpath(dirname(dirname(@__FILE__)),"deps","usr"))

    # Instantiate products here.  Examples:
    # libfoo = LibraryProduct(prefix, "libfoo")
    # foo_executable = ExecutableProduct(prefix, "fooifier")
    # libfoo_pc = FileProduct(joinpath(libdir(prefix), "pkgconfig", "libfoo.pc"))

    # Assign products to `products`:
    # products = [libfoo, foo_executable, libfoo_pc]

    # Download binaries from hosted location
    bin_prefix = "https://<path to hosted location such as GitHub Releases>"

    # Listing of files generated by BinaryBuilder:
    """)

    println("download_info = Dict(")
    for platform in sort(collect(keys(product_hashes)))
        fname, hash = product_hashes[platform]
        println("    $(platform) => (\"\$bin_prefix/$(fname)\", \"$(hash)\"),")
    end
    println(")")

    print("""
    if platform_key() in keys(download_info)
        # First, check to see if we're all satisfied
        if any(!satisfied(p; verbose=true) for p in products)
            # Download and install binaries
            url, tarball_hash = download_info[platform_key()]
            install(url, tarball_hash; prefix=prefix, force=true, verbose=true)
        end

        # Finally, write out a deps.jl file that will contain mappings for each
        # named product here: (there will be a "libfoo" variable and a "fooifier"
        # variable, etc...)
        @write_deps_file libfoo fooifier
    else
        error("Your platform \$(Sys.MACHINE) is not supported by this package!")
    end
    """)
end
