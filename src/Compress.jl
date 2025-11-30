module Compress

# TODO: import TOML for Julia 1.6
import Pkg.TOML
const STDLIB_TOML = VERSION >= v"1.6.0-DEV.764"
import Pkg.Types: VersionSpec, VersionRange, VersionBound

"""
    compress_versions(pool::Vector{VersionNumber}, subset::Vector{VersionNumber})

Given `pool` as the pool of available versions (of some package) and `subset` as some
subset of the pool of available versions, this function computes a `VersionSpec` which
includes all versions in `subset` and none of the versions in its complement.
"""
function compress_versions(pool::Vector{VersionNumber}, subset::Vector{VersionNumber})
    # Explicitly drop prerelease/build numbers, as those can confuse this.
    # TODO: Rewrite all this to use VersionNumbers instead of VersionBounds
    drop_build_prerelease(v::VersionNumber) = VersionNumber(v.major, v.minor, v.patch)
    pool = drop_build_prerelease.(pool)
    subset = sort!(drop_build_prerelease.(subset))

    complement = sort!(setdiff(pool, subset))
    ranges = VersionRange[]
    @label again
    isempty(subset) && return VersionSpec(ranges)
    a = first(subset)
    for b in reverse(subset)
        a.major == b.major || continue
        for m = 1:3
            lo = VersionBound((a.major, a.minor, a.patch)[1:m]...)
            for n = 1:3
                hi = VersionBound((b.major, b.minor, b.patch)[1:n]...)
                r = VersionRange(lo, hi)
                if !any(v in r for v in complement)
                    filter!(!in(r), subset)
                    push!(ranges, r)
                    @goto again
                end
            end
        end
    end
end
function compress_versions(pool::Vector{VersionNumber}, subset)
    compress_versions(pool, filter(in(subset), pool))
end

function load_versions(path::AbstractString)
    versions_file = joinpath(dirname(path), "Versions.toml")
    versions_dict = TOML.parsefile(versions_file)
    sort!([VersionNumber(v) for v in keys(versions_dict)])
end

function load(path::AbstractString,
              versions::Vector{VersionNumber} = load_versions(path))
    compressed = TOML.parsefile(path)
    uncompressed = Dict{VersionNumber,Dict{Any,Any}}()
    for (vers, data) in compressed
        vs = VersionSpec(vers)
        for v in versions
            v in vs || continue
            uv = get!(uncompressed, v, Dict())
            for (key, value) in data
                if haskey(uv, key)
                    error("Overlapping ranges for $(key) in Compat. Detected for version $(v).")
                else
                    uv[key] = value
                end
            end
        end
    end
    return uncompressed
end

function compress(path::AbstractString, uncompressed::Dict,
                  versions::Vector{VersionNumber} = load_versions(path))
    inverted = Dict{Pair{String,Any},Vector{VersionNumber}}()
    for (ver, data) in uncompressed, (key, val) in data
        val isa Base.UUID && (val = string(val))
        push!(get!(inverted, key => val, VersionNumber[]), ver)
    end
    compressed = Dict{String,Dict{String,Any}}()
    for ((k, v), vers) in inverted
        for r in compress_versions(versions, sort!(vers)).ranges
            # Existing version ranges in `Compat.toml` files are stored without spaces.
            # New version ranges are added with spaces in their string representation.
            # Remove all spaces, so that equal version ranges compare equal as strings.
            # This is a temporary work-around that will become unnecessary when
            # "all this is rewirtten to use VersionNumbers", as suggested above.
            get!(compressed, replace(string(r), " " => ""), Dict{String,Any}())[k] = v
        end
    end
    return compressed
end

function save(path::AbstractString, uncompressed::Dict,
              versions::Vector{VersionNumber} = load_versions(path))
    compressed = compress(path, uncompressed)
    open(path, write=true) do io
        if STDLIB_TOML
            TOML.print(string, io, compressed, sorted=true)
        else
            TOML.print(io, compressed, sorted=true)
        end
    end
end


#=
=#

end # module

