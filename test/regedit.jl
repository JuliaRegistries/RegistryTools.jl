using RegistryTools: DEFAULT_REGISTRY_URL,
    parse_registry,
    showsafe,
    registration_branch,
    get_registry,
    gitcmd
using LibGit2
import Pkg
using Pkg.TOML
using Pkg.Types: Project

using Test

const TEST_GITCONFIG = Dict(
    "user.name" => "RegistratorTests",
    "user.email" => "ci@juliacomputing.com",
)
const TEST_SIGNATURE = LibGit2.Signature(
    TEST_GITCONFIG["user.name"],
    TEST_GITCONFIG["user.email"],
)

function create_empty_registry(registry_path, registry_name, registry_uuid)
    mkpath(registry_path)
    registry_file = joinpath(registry_path, "Registry.toml")
    registry_data = RegistryTools.RegistryData(registry_name, registry_uuid)
    RegistryTools.write_registry(registry_file, registry_data)
end

@testset "RegistryTools" begin

@testset "Utilities" begin
    @testset "showsafe" begin
        @test string(showsafe(3)) == "3"
        @test string(showsafe(nothing)) == "nothing"
    end

    @testset "registration_branch" begin
        example = Project(Dict(
            "name" => "Example", "version" => "1.10.2",
            "uuid" => "698ec630-83b2-4a6d-81d4-a10176273030"
        ))
        url = "https://julialang.org/"
        @test registration_branch(example; url=url) == "registrator-example-698ec630-v1.10.2-0251df46a9"
    end
end

@testset "RegistryCache" begin
    @testset "get_registry" begin
        mktempdir(@__DIR__) do temp_cache_dir
            # test when registry is not in the cache and not downloaded
            cache = RegistryTools.RegistryCache(temp_cache_dir)
            with(get_registry(DEFAULT_REGISTRY_URL, cache=cache, gitconfig=TEST_GITCONFIG)) do repo
                @test LibGit2.path(repo) == replace(RegistryTools.path(cache, DEFAULT_REGISTRY_URL), '\\'=>'/')
                @test LibGit2.branch(repo) == "master"
                @test !LibGit2.isdirty(repo)
                @test LibGit2.url(LibGit2.lookup_remote(repo, "origin")) == DEFAULT_REGISTRY_URL
            end

            # test when registry is in the cache but not downloaded
            registry_path = RegistryTools.path(cache, DEFAULT_REGISTRY_URL)
            rm(registry_path, recursive=true, force=true)
            @test !ispath(registry_path)
            with(get_registry(DEFAULT_REGISTRY_URL, cache=cache, gitconfig=TEST_GITCONFIG)) do repo
                @test LibGit2.path(repo) == replace(RegistryTools.path(cache, DEFAULT_REGISTRY_URL), '\\'=>'/')
                @test LibGit2.branch(repo) == "master"
                @test !LibGit2.isdirty(repo)
                @test LibGit2.url(LibGit2.lookup_remote(repo, "origin")) == DEFAULT_REGISTRY_URL

                # test when registry is in the cache, downloaded, but mutated
                orig_hash = LibGit2.GitHash()
                LibGit2.branch!(repo, "newbranch", force=true)
                LibGit2.remove!(repo, "Registry.toml")
                LibGit2.commit(
                    repo,
                    "Removing Registry.toml in Registrator tests";
                    author=TEST_SIGNATURE,
                    committer=TEST_SIGNATURE,
                )
                @test LibGit2.GitObject(repo, "HEAD") != LibGit2.GitObject(repo, "master")
                @test ispath(registry_path)
            end
            with(get_registry(DEFAULT_REGISTRY_URL, cache=cache, gitconfig=TEST_GITCONFIG)) do repo
                @test LibGit2.path(repo) == replace(RegistryTools.path(cache, DEFAULT_REGISTRY_URL), '\\'=>'/')
                @test LibGit2.branch(repo) == "master"
                @test !LibGit2.isdirty(repo)
                @test LibGit2.url(LibGit2.lookup_remote(repo, "origin")) == DEFAULT_REGISTRY_URL
            end
        end
    end
end

@testset "RegistryData" begin
    blank = RegistryTools.RegistryData("BlankRegistry", "d4e2f5cd-0f48-4704-9988-f1754e755b45")

    example = Project(Dict(
        "name" => "Example", "uuid" => "7876af07-990d-54b4-ab0e-23690620f79a"
    ))

    @testset "I/O" begin
        registry = """
            name = "General"
            uuid = "23338594-aafe-5451-b93e-139f81909106"
            repo = "https://github.com/JuliaRegistries/General.git"

            description = \"\"\"
            Official general Julia package registry where people can
            register any package they want without too much debate about
            naming and without enforced standards on documentation or
            testing. We nevertheless encourage documentation, testing and
            some amount of consideration when choosing package names.
            \"\"\"

            [packages]
            00701ae9-d1dc-5365-b64a-a3a3ebf5695e = { name = "BioAlignments", path = "B/BioAlignments" }
            00718b61-6157-5045-8849-3d4c4093d022 = { name = "Convertible", path = "C/Convertible" }
            0087ddc6-3964-5e57-817f-9937aefb0357 = { name = "MathOptInterfaceMosek", path = "M/MathOptInterfaceMosek" }
            """

        registry_data = parse_registry(IOBuffer(registry))
        @test registry_data isa RegistryTools.RegistryData
        written_registry = sprint(TOML.print, registry_data)
        written_registry_data = parse_registry(IOBuffer(written_registry))

        @test written_registry_data == registry_data
        @test written_registry == registry
    end

    @testset "Package Operations" begin
        registry_data = copy(blank)

        @test isempty(registry_data.packages)
        @test push!(registry_data, example) == registry_data
        @test length(registry_data.packages) == 1
        @test haskey(registry_data.packages, string(example.uuid))
        @test registry_data.packages[string(example.uuid)]["name"] == "Example"
        @test registry_data.packages[string(example.uuid)]["path"] == RegistryTools.package_relpath("Example")
    end
end

@testset "check_version!" begin
    import RegistryTools: ReturnStatus, check_version!, haserror
    import Pkg.Types: Project
    function hascheck(status::ReturnStatus, check)
        return check in (c.id for c in status.triggered_checks)
    end

    for ver in [v"0.0.2", v"0.3.2", v"4.3.2"]
        status = ReturnStatus()
        check_version!(ver, VersionNumber[], status)
        @test hascheck(status, :not_standard_first_version)
        @test hascheck(status, :new_package_label)
        @test length(status.triggered_checks) == 2
        @test !haserror(status)
    end

    for ver in [v"0.0.1", v"0.1.0", v"1.0.0"]
        status = ReturnStatus()
        check_version!(ver, VersionNumber[], status)
        @test hascheck(status, :new_package_label)
        @test length(status.triggered_checks) == 1
        @test !haserror(status)
    end

    versions_list = [v"0.0.5", v"0.1.0", v"0.1.5", v"1.0.0"]
    let    # Less than least existing version
        ver = v"0.0.4"
        status = ReturnStatus()
        check_version!(ver, versions_list, status)
        @test hascheck(status, :version_less_than_all_existing)
        @test length(status.triggered_checks) == 1
        @test !haserror(status)
    end

    let    # Existing version
        ver = v"0.0.5"
        status = ReturnStatus()
        check_version!(ver, versions_list, status)
        @test hascheck(status, :version_exists)
        @test length(status.triggered_checks) == 1
        @test haserror(status)
    end

    # Non-existing version
    for (ver, type) in [(v"0.1.1", "patch"), (v"0.1.6", "patch"), (v"1.0.1", "patch"), (v"1.1.0", "minor")]
        status = ReturnStatus()
        check_version!(ver, versions_list, status)
        @test hascheck(status, Symbol(type, "_release"))
        @test length(status.triggered_checks) == 1
        @test !haserror(status)
    end
    for (ver, type) in [(v"0.0.6", "patch"), (v"0.2.0", "minor"), (v"2.0.0", "major")]
        status = ReturnStatus()
        check_version!(ver, versions_list, status)
        @test hascheck(status, Symbol(type, "_release"))
        @test hascheck(status, :breaking)
        @test length(status.triggered_checks) == 2
        @test !haserror(status)
    end

    # Skip a version
    for (ver, type) in [(v"0.1.2", "patch"), (v"0.1.7", "patch"), (v"1.0.2", "patch"), (v"1.2.0", "minor")]
        status = ReturnStatus()
        check_version!(ver, versions_list, status)
        @test hascheck(status, Symbol(type, "_release"))
        @test hascheck(status, :version_skip)
        @test length(status.triggered_checks) == 2
        @test !haserror(status)
    end
    for (ver, type) in [(v"0.0.7", "patch"), (v"0.3.0", "minor"), (v"3.0.0", "major")]
        status = ReturnStatus()
        check_version!(ver, versions_list, status)
        @test hascheck(status, Symbol(type, "_release"))
        @test hascheck(status, :breaking)
        @test hascheck(status, :version_skip)
        @test length(status.triggered_checks) == 3
        @test !haserror(status)
    end
end

@testset "package_file" begin
    import RegistryTools: check_package!, update_package_file
    mktempdir(@__DIR__) do package_path
        uuid = "698ec630-83b2-4a6d-81d4-a10176273030"
        pkg = Project(Dict("name" => "Example", "uuid" => uuid))
        repo = "https://example.com/example.git"
        status = ReturnStatus()
        @test check_package!("", package_path, status) == ""
        @test haserror(status)
        status = ReturnStatus()
        @test check_package!(repo, package_path, status) == repo
        @test !haserror(status)
        update_package_file(pkg, repo, "", package_path)
        package_file = joinpath(package_path, "Package.toml")
        @test isfile(package_file)
        @test read(package_file, String) == """
                                            name = "Example"
                                            uuid = "$uuid"
                                            repo = "$repo"
                                            """
        status = ReturnStatus()
        @test check_package!("", package_path, status) == repo
        @test !haserror(status)
        status = ReturnStatus()
        @test check_package!(repo, package_path, status) == repo
        @test !haserror(status)
    end
end

@testset "find_package_in_registry" begin
    import RegistryTools: find_package_in_registry
    mktempdir(@__DIR__) do temp_dir
        registry_path = temp_dir
        registry_uuid = "d4e2f5cd-0f48-4704-9988-f1754e755b45"
        create_empty_registry(registry_path, "TestRegistry", registry_uuid)
        registry_file = joinpath(registry_path, "Registry.toml")
        registry_data = parse_registry(registry_file)
        package_uuid = "698ec630-83b2-4a6d-81d4-a10176273030"
        pkg = Project(Dict("name" => "Example",
                           "uuid" => package_uuid))
        status = ReturnStatus()

        find_package_in_registry(pkg, registry_file, registry_path,
                                 registry_data, status)
        @test read(registry_file, String) == """
                                             name = "TestRegistry"
                                             uuid = "$(registry_uuid)"

                                             [packages]
                                             $(package_uuid) = { name = "Example", path = "$(RegistryTools.package_relpath("Example"))" }
                                             """
        @test isdir(joinpath(registry_path, RegistryTools.package_relpath("Example")))
    end
end

@testset "versions_file" begin
    import RegistryTools: get_versions_file, update_versions_file, check_versions!
    mktempdir(@__DIR__) do temp_dir
        pkg = Project(version = v"1.0.0")
        tree_hash = repeat("0", 40)
        status = ReturnStatus()

        filename, data = get_versions_file(temp_dir)
        @test filename == joinpath(temp_dir, "Versions.toml")
        @test data isa Dict
        @test isempty(data)
        check_versions!(pkg, data, status)
        # No previous version registered, this version is fine.
        @test !haserror(status)

        update_versions_file(pkg, filename, data, tree_hash)

        _, data = get_versions_file(temp_dir)
        @test data isa Dict
        @test collect(keys(data)) == ["1.0.0"]
        @test data["1.0.0"] isa Dict
        @test collect(keys(data["1.0.0"])) == ["git-tree-sha1"]
        @test data["1.0.0"]["git-tree-sha1"] == tree_hash

        check_versions!(pkg, data, status)
        # This version was just registered, should be a complaint now.
        @test haserror(status)
    end
end

@testset "deps_file" begin
    import RegistryTools: update_deps_file
    mktempdir(@__DIR__) do temp_dir
        uuid = Base.UUID("8dfed614-e22c-5e08-85e1-65c5234f0b40")
        deps = Dict("Test" => uuid)
        pkg = Project(version = v"1.0.0", deps = deps)
        update_versions_file(pkg, joinpath(temp_dir, "Versions.toml"),
                             Dict{String, Any}(), repeat("0", 40))
        update_deps_file(pkg, temp_dir, VersionNumber[])
        deps_file = joinpath(temp_dir, "Deps.toml")
        @test isfile(deps_file)
        @test read(deps_file, String) == """
                                         [1]
                                         Test = "$uuid"
                                         """
    end
end

@testset "compat_file" begin
    import RegistryTools: update_compat_file
    mktempdir(@__DIR__) do temp_dir
        compat = Dict("julia" => "1.3")
        if Base.VERSION >= v"1.7-"
            compat2 = Dict((k, Pkg.Types.Compat(Pkg.Types.semver_spec(v), v)) for (k, v) in compat)
            pkg = Project(version = v"1.0.0", compat = compat2)
        else
            pkg = Project(version = v"1.0.0", compat = compat)
        end
        update_versions_file(pkg, joinpath(temp_dir, "Versions.toml"),
                             Dict{String, Any}(), repeat("0", 40))
        update_compat_file(pkg, temp_dir, VersionNumber[])
        compat_file = joinpath(temp_dir, "Compat.toml")
        @test isfile(compat_file)
        @test read(compat_file, String) == """
                                           [1]
                                           julia = "1.3.0-1"
                                           """
    end
end

@testset "registry updates" begin
    import RegistryTools: RegistryData, ReturnStatus, haserror,
                          write_registry, check_and_update_registry_files,
                          RegBranch, set_metadata!
    import Pkg.Types: read_project
    registry_update_tests =
        [
            # Add one simple package.
            (project_files = ["Example1"],
             status = Symbol[:new_package, :new_package_label],
             regbranch = (error = false, warning = false,
                          kind = "New package", labels = String["new package"]))

            # Increase patch revision.
            (project_files = ["Example1", "Example2"],
             status = Symbol[:new_version, :patch_release],
             regbranch = (error = false, warning = false,
                          kind = "New version",
                          labels = String["patch release"]))

            # Increase minor revision.
            (project_files = ["Example1", "Example2", "Example3"],
             status = Symbol[:new_version, :minor_release],
             regbranch = (error = false, warning = false,
                          kind = "New version",
                          labels = String["minor release"]))

            # Increase major revision.
            (project_files = ["Example1", "Example4"],
             status = Symbol[:new_version, :major_release, :breaking],
             regbranch = (error = false, warning = false,
                          kind = "New version",
                          labels = String["major release", "BREAKING"]))

            # Adding a minor revision after next major revision has
            # been registered.
            (project_files = ["Example1", "Example4", "Example3"],
             status = Symbol[:new_version, :minor_release],
             regbranch = (error = false, warning = false,
                          kind = "New version",
                          labels = String["minor release"]))

            # Adding a revision that comes before all registered versions.
            (project_files = ["Example2", "Example4", "Example3", "Example1"],
             status = Symbol[:new_version, :version_less_than_all_existing],
             regbranch = (error = true, warning = false,
                          kind = "New version", labels = String[]))

            # Adding a revision that comes before all registered versions.
            # This time disable this as an error in RegBranch.
            (project_files = ["Example2", "Example4", "Example3", "Example1"],
             disable_regbranch_errors = [:version_less_than_all_existing],
             status = Symbol[:new_version, :version_less_than_all_existing],
             regbranch = (error = false, warning = true,
                          kind = "New version", labels = String[]))

            # Non-standard first version.
            (project_files = ["Example2"],
             status = Symbol[:new_package, :new_package_label,
                             :not_standard_first_version],
             regbranch = (error = false, warning = true,
                          kind = "New package", labels = String["new package"]))

            # Version zero.
            (project_files = ["Example5"],
             status = Symbol[:new_package, :new_package_label, :version_zero,
                             :not_standard_first_version],
             regbranch = (error = true, warning = true,
                          kind = "New package", labels = String["new package"]))

            # Skipped versions.
            (project_files = ["Example1", "Example6"],
             status = Symbol[:new_version, :minor_release, :version_skip],
             regbranch = (error = false, warning = true,
                          kind = "New version",
                          labels = String["minor release"]))

            # Adding an existing version.
            (project_files = ["Example1", "Example1"],
             status = Symbol[:new_version, :version_exists],
             regbranch = (error = true, warning = false,
                          kind = "New version",
                          labels = String[]))

            # Changing name.
            (project_files = ["Example1", "Example7"],
             status = Symbol[:change_package_name],
             regbranch = (error = true, warning = false,
                          kind = "",
                          labels = String[]))

            # Changing uuid.
            (project_files = ["Example1", "Example8"],
             status = Symbol[:change_package_uuid],
             regbranch = (error = true, warning = false,
                          kind = "",
                          labels = String[]))

            # Incorrect stdlib uuid.
            (project_files = ["Example9"],
             status = Symbol[:new_package, :new_package_label,
                             :wrong_stdlib_uuid],
             regbranch = (error = true, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Dependency on itself.
            (project_files = ["Example10"],
             status = Symbol[:new_package, :new_package_label,
                             :package_self_dep],
             regbranch = (error = true, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Incorrect spelling of an stdlib.
            # (Arguably this should complain differently since the
            # UUID is known.)
            (project_files = ["Example11"],
             status = Symbol[:new_package, :new_package_label,
                             :dependency_not_found],
             regbranch = (error = true, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Missing dependency.
            (project_files = ["Example12"],
             status = Symbol[:new_package, :new_package_label,
                             :dependency_not_found],
             regbranch = (error = true, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Dependency no longer missing.
            (project_files = ["Dep1", "Example12"],
             status = Symbol[:new_package, :new_package_label],
             regbranch = (error = false, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Dependency not missing but incorrectly spelled.
            (project_files = ["Dep1", "Example13"],
             status = Symbol[:new_package, :new_package_label, :name_mismatch],
             regbranch = (error = true, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Compatibility with Julia before 0.7.
            (project_files = ["Example14"],
             status = Symbol[:new_package, :new_package_label,
                             :julia_before_07_in_compat],
             regbranch = (error = true, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Compat for non-dependency. On Julia 1.2 and later this
            # gives an error already in `read_project`, so only run it
            # on Julia 1.1.
            (project_files = ["Example15"],
             skip_for_newer_julia = true,
             status = Symbol[:new_package, :new_package_label,
                             :invalid_compat],
             regbranch = (error = true, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Compat entry for package in deps.
            (project_files = ["Dep1", "Example16"],
             status = Symbol[:new_package, :new_package_label],
             regbranch = (error = false, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Compat entry for package in extras.
            (project_files = ["Dep1", "Example17"],
             status = Symbol[:new_package, :new_package_label],
             regbranch = (error = false, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Change package repo.
            (project_files = ["Example1", "Example2"],
             modify_package_repo = "Example2",
             status = Symbol[:new_version, :patch_release, :change_package_url],
             regbranch = (error = true, warning = false,
                          kind = "New version",
                          labels = String["patch release"]))

            # Register new package with empty package repo string.
            (project_files = ["Example1"],
             no_package_repo = "Example1",
             status = Symbol[:new_package, :package_url_missing],
             regbranch = (error = true, warning = false,
                          kind = "New package",
                          labels = String[]))

            # Register new version with empty package repo string.
            (project_files = ["Example1", "Example2"],
             no_package_repo = "Example2",
             status = Symbol[:new_version, :patch_release],
             regbranch = (error = false, warning = false,
                          kind = "New version",
                          labels = String["patch release"]))
        ]


    mktempdir(@__DIR__) do temp_dir
        registry_path = joinpath(temp_dir, "registry")
        projects_path = joinpath(@__DIR__, "project_files")
        registry_deps_paths = String[]
        tree_hash = repeat("0", 40)
        for test_data in registry_update_tests
            if haskey(test_data, :skip_for_newer_julia) && VERSION >= v"1.2"
                continue
            end
            # Clean up from previous iteration.
            isdir(registry_path) && rm(registry_path, recursive = true)
            # Start with an empty registry.
            create_empty_registry(registry_path, "TestRegistry",
                                  "d4e2f5cd-0f48-4704-9988-f1754e755b45")
            local status, regbr
            # Register some packages.
            for project in test_data.project_files
                project_file = joinpath(projects_path, "$(project).toml")
                pkg = read_project(project_file)
                # Create status object.
                status = ReturnStatus()
                regbr = RegBranch(pkg, "")
                package_repo = "http://example.com/$(pkg.name).git"
                if get(test_data, :modify_package_repo, "") == project
                    package_repo = "http://example.org/$(pkg.name).git"
                elseif get(test_data, :no_package_repo, "") == project
                    package_repo = ""
                end
                check_and_update_registry_files(pkg, package_repo, tree_hash,
                                                registry_path,
                                                registry_deps_paths, status)
                haserror(status) && break
            end
            # Test the return status of the last package registration.
            @test sort([check.id for check in status.triggered_checks]) == sort(test_data.status)
            # Add Registrator's errors before filling in RegBranch.
            union!(status.errors,
                   setdiff(RegistryTools.registrator_errors,
                           get(test_data, :disable_regbranch_errors, [])))
            set_metadata!(regbr, status)
            @test haskey(regbr.metadata, "error") == test_data.regbranch.error
            @test haskey(regbr.metadata, "warning") == test_data.regbranch.warning
            @test get(regbr.metadata, "kind", "") == test_data.regbranch.kind
            @test sort(get(regbr.metadata, "labels", String[])) == sort(test_data.regbranch.labels)
        end
    end
end

# Helper function for the next testset.
function create_and_populate_registry(registry_path, registry_name,
                                      registry_uuid, package)
    # Create an empty registry.
    create_empty_registry(registry_path, registry_name, registry_uuid)

    # Add a package.
    projects_path = joinpath(@__DIR__, "project_files")
    project_file = joinpath(projects_path, "$(package).toml")
    pkg = read_project(project_file)
    package_repo = "http://example.com/$(pkg.name).git"
    tree_hash = repeat("0", 40)
    registry_deps_paths = String[]
    status = ReturnStatus()
    check_and_update_registry_files(pkg, package_repo, tree_hash,
                                    registry_path,
                                    registry_deps_paths, status)

    # Turn the registry into a git repository.
    git = gitcmd(registry_path, TEST_GITCONFIG)
    run(`$git init`)
    run(`$git add .`)
    run(`$git commit -m .`)

    return status
end

# Test the `register` function in its entirety as well as having a
# dependency in a different registry.
#
# The strategy is to first create two registries and populate them
# with one package each. Then `register` is called to register a new
# version of one of the packages with a dependency to the other
# package. The registration is pushed to a new branch via a file URL.
@testset "register" begin
    mktempdir(@__DIR__) do temp_dir
        registry1_path = joinpath(temp_dir, "Registry1")
        status = create_and_populate_registry(registry1_path, "Registry1",
                                              "7e1d4fce-5fe6-405e-8bac-078d4138e9a2",
                                              "Example1")
        @test !haserror(status)

        registry2_path = joinpath(temp_dir, "Registry2")
        status = create_and_populate_registry(registry2_path, "Registry2",
                                              "a5a8be26-c942-4674-beee-533a0e81ac1d",
                                              "Dep1")
        @test !haserror(status)

        projects_path = joinpath(@__DIR__, "project_files")
        project_file = joinpath(projects_path, "Example18.toml")
        pkg = read_project(project_file)
        package_repo = "http://example.com/$(pkg.name).git"
        tree_hash = repeat("0", 40)
        registry_repo = "file://$(registry1_path)"
        deps_repo = "file://$(registry2_path)"
        regbr = register(package_repo, pkg, tree_hash, registry = registry_repo,
                         registry_deps = [deps_repo], push = true,
                         gitconfig = TEST_GITCONFIG)
        @test !haskey(regbr.metadata, "error") && !haskey(regbr.metadata, "warning")
        git = gitcmd(registry1_path, TEST_GITCONFIG)
        branches = readlines(`$git branch`)
        @test length(branches) == 2
    end

    # Clean up the registry cache created by `register`.
    rm(joinpath(@__DIR__, "registries", "7e1d4fce-5fe6-405e-8bac-078d4138e9a2"),
       recursive = true)
    rm(joinpath(@__DIR__, "registries", "a5a8be26-c942-4674-beee-533a0e81ac1d"),
       recursive = true)
    rm(joinpath(@__DIR__, "registries"))
end

@testset "find_registered_version" begin
    mktempdir(@__DIR__) do temp_dir
        registry_path = temp_dir

        # Create an empty registry.
        create_empty_registry(registry_path, "Registry1",
                              "7e1d4fce-5fe6-405e-8bac-078d4138e9a2")

        # Add a package.
        projects_path = joinpath(@__DIR__, "project_files")
        project_file = joinpath(projects_path, "Example1.toml")
        pkg = read_project(project_file)
        @test find_registered_version(pkg, registry_path) == ""

        package_repo = string("http://example.com/$(pkg.name).git")
        tree_hash = "7dd821daaae58ddf9fee53e00aa1aab33794d130"
        registry_deps_paths = String[]
        status = ReturnStatus()
        check_and_update_registry_files(pkg, package_repo, tree_hash,
                                        registry_path,
                                        registry_deps_paths, status)

        @test find_registered_version(pkg, registry_path) == tree_hash
        project_file = joinpath(projects_path, "Example2.toml")
        pkg = read_project(project_file)
        @test find_registered_version(pkg, registry_path) == ""
    end
end

@testset "Sorted (recursive) TOML.print for Versions.toml file" begin
    pkg = Project(version = v"2.0.0")
    # versions_file = "Versions.toml"
    version_data = Dict{String,Any}(
         "1.0.0" => Dict("yanked"=>true,"git-tree-sha1"=>"b04b6c6bfd3a607aa1b85362b4854ef612137f3e"),
         "3.0.0" => Dict("git-tree-sha1"=>"96429a372b5c4ad63fa9cbff6ba4178a85939705","foo"=>"bar")
    )
    tree_hash = "20cd0a2651eaf28c8a76c8d7fea4f1107f20174b"
    mktemp() do path, io
        RegistryTools.update_versions_file(pkg, path, version_data, tree_hash::AbstractString)
        close(io)
        @test read(path, String) ==
        """
        ["1.0.0"]
        git-tree-sha1 = "b04b6c6bfd3a607aa1b85362b4854ef612137f3e"
        yanked = true

        ["2.0.0"]
        git-tree-sha1 = "20cd0a2651eaf28c8a76c8d7fea4f1107f20174b"

        ["3.0.0"]
        git-tree-sha1 = "96429a372b5c4ad63fa9cbff6ba4178a85939705"
        foo = "bar"
        """
    end
end

@testset "subdirectory" begin
    import RegistryTools: ReturnStatus, check_and_update_registry_files
    import Pkg.Types: read_project

    mktempdir(@__DIR__) do temp_dir
        registry_path = joinpath(temp_dir, "registry")
        projects_path = joinpath(@__DIR__, "project_files")
        registry_deps_paths = String[]
        tree_hash = repeat("0", 40)
        # Start with an empty registry.
        create_empty_registry(registry_path, "TestRegistry",
                              "d4e2f5cd-0f48-4704-9988-f1754e755b45")
        # Register a package without subdir (default).
        project_file = joinpath(projects_path, "Example1.toml")
        pkg = read_project(project_file)
        status = ReturnStatus()
        package_repo = "http://example.com/Example1.git"
        check_and_update_registry_files(pkg, package_repo, tree_hash,
                                        registry_path,
                                        registry_deps_paths, status)
        path = RegistryTools.package_relpath("Example")
        @test read(joinpath(registry_path, path, "Package.toml"), String) ==
            """
            name = "Example"
            uuid = "d7508571-2240-4c50-b21c-240e414cc6d2"
            repo = "$(package_repo)"
            """

        # Register a package with subdir.
        project_file = joinpath(projects_path, "Dep1.toml")
        pkg = read_project(project_file)
        status = ReturnStatus()
        package_repo = "http://example.com/BigRepo.git"
        check_and_update_registry_files(pkg, package_repo, tree_hash,
                                        registry_path,
                                        registry_deps_paths, status,
                                        subdir = "packages/Dep")
        path = RegistryTools.package_relpath("Dep")
        @test read(joinpath(registry_path, path, "Package.toml"), String) ==
            """
            name = "Dep"
            uuid = "49c7135d-e2b1-4bed-912f-5371fe4924fa"
            repo = "$(package_repo)"
            subdir = "packages/Dep"
            """
    end
end

@testset "weakdeps" begin
    import RegistryTools: ReturnStatus, check_and_update_registry_files
    import Pkg.Types: read_project

    temp_dir = mktempdir(; cleanup=false)
    mktempdir(@__DIR__) do temp_dir
        registry_path = joinpath(temp_dir, "registry")
        projects_path = joinpath(@__DIR__, "project_files")
        registry_deps_paths = String[]
        tree_hash = repeat("0", 40)
        # Start with an empty registry.
        create_empty_registry(registry_path, "TestRegistry",
                              "d4e2f5cd-0f48-4704-9988-f1754e755b45")
        project_file = joinpath(projects_path, "Example19.toml")
        pkg = read_project(project_file)
        status = ReturnStatus()
        package_repo = "http://example.com/Example1.git"
        check_and_update_registry_files(pkg, package_repo, tree_hash,
                                        registry_path,
                                        registry_deps_paths, status)
        path = RegistryTools.package_relpath("Example")
        @test read(joinpath(registry_path, path, "Compat.toml"), String) ==
            """
            [1]
            UUIDs = "1.8.0-1"
            julia = "1.1.0-1"
            """
        @test read(joinpath(registry_path, path, "WeakCompat.toml"), String) ==
            """
            [1]
            UUIDs = "1.8.0-1"
            """
        @test read(joinpath(registry_path, path, "Deps.toml"), String) ==
              read(joinpath(registry_path, path, "WeakDeps.toml"), String) ==
            """
            [1]
            UUIDs = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"
            """
    end
end

@testset "The `RegistryTools.package_relpath` function" begin
    @test RegistryTools.package_relpath("Example") == "E/Example"
end

end
