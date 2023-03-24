import SHA
import HTTP

showsafe(x) = (x === nothing) ? "nothing" : x

function gitcmd(path::AbstractString, gitconfig::Dict)
    cmd = ["git", "-C", path]
    for (n,v) in gitconfig
        push!(cmd, "-c")
        push!(cmd, "$n=$v")
    end
    Cmd(cmd)
end

"""
    registration_branch(pkg::RegistryTools.Project; url::AbstractString) -> String

Generate the name for the registry branch used to register the package version.
"""
function registration_branch(pkg::Project; url::AbstractString)
    url_hash = bytes2hex(SHA.sha256(url))
    url_hash_trunc = url_hash[1:10]
    return "registrator-$(lowercase(pkg.name))-$(string(pkg.uuid)[1:8])-v$(pkg.version)-$(url_hash_trunc)"
end

# Returns true if the two urls are the same. When the two urls are different
# returns true if the only difference between the two urls is a .git at the end
# or if only the scheme (http/https/ssh) is different. Returns false otherwise
function same_pkg_url(urla::AbstractString, urlb::AbstractString)
    same_pkg_url(HTTP.URI(string(urla)), HTTP.URI(string(urlb)))
end

function same_pkg_url(urla::HTTP.URI, urlb::HTTP.URI)
    urla.host == urlb.host && same_pkg_path(urla.path, urlb.path)
end

function same_pkg_path(patha::AbstractString, pathb::AbstractString)
    if patha == pathb
        return true
    end

    if endswith(patha, ".git")
        return patha[1:end-4] == pathb
    elseif endswith(pathb, ".git")
        return pathb[1:end-4] == patha
    end

    return false
end
