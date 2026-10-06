# json2dir: create the directory tree a JSON document describes, in the current directory.
# Implements RFC J2D-1 (https://github.com/kitsunoff/awesome-json2dir/blob/main/spec/rfc-json2dir.md).
# Base Julia only: a small hand-written JSON parser, no packages.

struct J2DError <: Exception
    msg::String
end

fail(msg) = throw(J2DError(msg))

# A parsed value is a String, a Dict{String,Any} (object) or a Vector{Any} (array).
# Numbers, true, false and null are rejected while parsing (§4: they have no meaning).

mutable struct Parser
    b::Vector{UInt8}
    i::Int
end

peek(p::Parser) = p.i <= length(p.b) ? p.b[p.i] : 0x00
ateof(p::Parser) = p.i > length(p.b)

function skipws(p::Parser)
    while !ateof(p) && p.b[p.i] in (0x20, 0x09, 0x0a, 0x0d)
        p.i += 1
    end
end

function expect(p::Parser, c::UInt8)
    (ateof(p) || p.b[p.i] != c) && fail("invalid JSON: expected '$(Char(c))' at byte $(p.i)")
    p.i += 1
end

function hex4(p::Parser)
    p.i + 3 <= length(p.b) || fail("invalid JSON: truncated \\u escape")
    v = 0
    for k in 0:3
        c = p.b[p.i+k]
        d = 0x30 <= c <= 0x39 ? c - 0x30 :
            0x61 <= c <= 0x66 ? c - 0x61 + 10 :
            0x41 <= c <= 0x46 ? c - 0x41 + 10 : fail("invalid JSON: bad \\u escape")
        v = v * 16 + d
    end
    p.i += 4
    return v
end

function pututf8(out::Vector{UInt8}, cp::Int)
    append!(out, codeunits(string(Char(cp))))
end

function parse_string(p::Parser)
    expect(p, UInt8('"'))
    out = UInt8[]
    while true
        ateof(p) && fail("invalid JSON: unterminated string")
        c = p.b[p.i]
        p.i += 1
        if c == UInt8('"')
            return String(out)
        elseif c == UInt8('\\')
            ateof(p) && fail("invalid JSON: unterminated escape")
            e = p.b[p.i]
            p.i += 1
            if e == UInt8('"') || e == UInt8('\\') || e == UInt8('/')
                push!(out, e)
            elseif e == UInt8('b'); push!(out, 0x08)
            elseif e == UInt8('f'); push!(out, 0x0c)
            elseif e == UInt8('n'); push!(out, 0x0a)
            elseif e == UInt8('r'); push!(out, 0x0d)
            elseif e == UInt8('t'); push!(out, 0x09)
            elseif e == UInt8('u')
                cp = hex4(p)
                if 0xd800 <= cp <= 0xdbff
                    if p.i + 1 <= length(p.b) && p.b[p.i] == UInt8('\\') && p.b[p.i+1] == UInt8('u')
                        p.i += 2
                        lo = hex4(p)
                        0xdc00 <= lo <= 0xdfff || fail("string contains an unpaired surrogate")
                        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00)
                    else
                        fail("string contains an unpaired surrogate")
                    end
                elseif 0xdc00 <= cp <= 0xdfff
                    fail("string contains an unpaired surrogate")
                end
                pututf8(out, cp)
            else
                fail("invalid JSON: bad escape")
            end
        elseif c < 0x20
            fail("invalid JSON: control character in string")
        else
            push!(out, c)
        end
    end
end

function parse_value(p::Parser, depth::Int)
    depth > 10000 && fail("document nested too deeply")
    skipws(p)
    c = peek(p)
    if c == UInt8('"')
        return parse_string(p)
    elseif c == UInt8('{')
        p.i += 1
        obj = Dict{String,Any}()
        skipws(p)
        if peek(p) == UInt8('}')
            p.i += 1
            return obj
        end
        while true
            skipws(p)
            k = parse_string(p)
            skipws(p)
            expect(p, UInt8(':'))
            obj[k] = parse_value(p, depth + 1)   # duplicate names: last one wins (§4.2)
            skipws(p)
            if peek(p) == UInt8(',')
                p.i += 1
            else
                expect(p, UInt8('}'))
                return obj
            end
        end
    elseif c == UInt8('[')
        p.i += 1
        arr = Any[]
        skipws(p)
        if peek(p) == UInt8(']')
            p.i += 1
            return arr
        end
        while true
            push!(arr, parse_value(p, depth + 1))
            skipws(p)
            if peek(p) == UInt8(',')
                p.i += 1
            else
                expect(p, UInt8(']'))
                return arr
            end
        end
    elseif ateof(p)
        fail("invalid JSON: unexpected end of input")
    elseif c == UInt8('-') || UInt8('0') <= c <= UInt8('9') || c in (UInt8('t'), UInt8('f'), UInt8('n'))
        fail("numbers, true, false and null are not allowed")
    else
        fail("invalid JSON: unexpected byte at $(p.i)")
    end
end

function parse_document(bytes::Vector{UInt8})
    isvalid(String, bytes) || fail("input is not valid UTF-8")
    p = Parser(bytes, 1)
    # §3: a leading byte order mark may be ignored.
    if length(bytes) >= 3 && bytes[1] == 0xef && bytes[2] == 0xbb && bytes[3] == 0xbf
        p.i = 4
    end
    v = parse_value(p, 0)
    skipws(p)
    ateof(p) || fail("invalid JSON: trailing data")
    return v
end

function check_name(name::String, where)
    if name == "" || name == "." || name == ".." || occursin('/', name) || occursin('\0', name)
        fail("$where: invalid name $(repr(name))")
    end
end

# §4, §6: validate the whole document before touching the file system.
function validate(v, where)
    v isa String && return
    if v isa Vector
        (length(v) == 2 && v[1] isa String && v[2] isa String) ||
            fail("$where: an array must be [\"link\", target] or [\"script\", content]")
        v[1] in ("link", "script") || fail("$where: unknown array kind $(repr(v[1]))")
        v[1] == "link" && occursin('\0', v[2]) && fail("$where: a link target cannot contain NUL")
        return
    end
    for (name, child) in v
        w = where == "." ? name : "$where/$name"
        check_name(name, w)
        validate(child, w)
    end
end

lexists(p) = ispath(p) || islink(p)

# §5.2–5.4: remove an existing non-directory (never following a symlink); a directory is an error.
function clear(p)
    lexists(p) || return
    st = lstat(p)
    isdir(st) && fail("$p: a directory is in the way")
    rm(p)
end

function writefile(p, content::String, executable::Bool)
    flags = Base.Filesystem.JL_O_WRONLY | Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_EXCL
    f = Base.Filesystem.open(p, flags, 0o666)
    try
        write(f, content)
    finally
        close(f)
    end
    executable && chmod(p, (filemode(p) & 0o7777) | 0o111)
end

function apply(dir, tree::Dict{String,Any})
    for name in sort!(collect(keys(tree)); by = codeunits)
        p = dir == "." ? name : joinpath(dir, name)
        v = tree[name]
        if v isa String
            clear(p)
            writefile(p, v, false)
        elseif v isa Vector
            clear(p)
            if v[1] == "link"
                symlink(v[2], p)
            else
                writefile(p, v[2], true)
            end
        else
            if !(lexists(p) && isdir(lstat(p)))
                lexists(p) && rm(p)
                mkdir(p)
            end
            apply(p, v)
        end
    end
end

function main()
    if !isempty(ARGS)
        println(stderr, "usage: json2dir < document.json")
        return 2
    end
    try
        doc = parse_document(read(stdin))
        doc isa Dict || fail("the root of the document must be an object")
        validate(doc, ".")
        apply(".", doc)
        return 0
    catch e
        msg = e isa J2DError ? e.msg : sprint(showerror, e)
        println(stderr, "json2dir: ", msg)
        return 1
    end
end

exit(main())
