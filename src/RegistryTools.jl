module RegistryTools

export RegBranch
export register
export check_and_update_registry_files
export find_registered_version

import LibGit2
using Pkg: Pkg, TOML, GitTools
using UUIDs: UUID

const DEFAULT_REGISTRY_URL = "https://github.com/JuliaRegistries/General"

include("Compress.jl")
include("builtin_pkgs.jl")
include("types.jl")
include("register.jl")
include("utils.jl")

end
