#-------------------------------------------------------------------------------
# AST interface, built on top of raw tree

abstract type AbstractSyntaxData end

# TODO:
#
# Investigate attributes in ECS form and immutable trees.
# Key advantages of immutable trees:
#   * Leaves are stored inline
#   * No need for to ever do "copyast"
# Key advantages of ECS:
#   * Multiple attributes without changing the concrete data structure

mutable struct TreeNode{NodeData}   # ? prevent others from using this with NodeData <: AbstractSyntaxData?
    parent::Union{Nothing,TreeNode{NodeData}}
    children::Union{Nothing,Vector{TreeNode{NodeData}}}
    data::Union{Nothing,NodeData}

    # Use this constructor rather than the automatically generated one to pass
    # Test.detect_unbound_args() test in Base.
    function TreeNode{NodeData}(parent::Union{Nothing,TreeNode{NodeData}},
                                children::Union{Nothing,Vector{TreeNode{NodeData}}},
                                data::Union{Nothing,NodeData}) where {NodeData}
        new{NodeData}(parent, children, data)
    end
end

# Implement "pass-through" semantics for field access: access fields of `data`
# as if they were part of `TreeNode`
function Base.getproperty(node::TreeNode, name::Symbol)
    name === :parent && return getfield(node, :parent)
    name === :children && return getfield(node, :children)
    d = getfield(node, :data)
    name === :data && return d
    return getproperty(d, name)
end

function Base.setproperty!(node::TreeNode, name::Symbol, x)
    name === :parent && return setfield!(node, :parent, x)
    name === :children && return setfield!(node, :children, x)
    name === :data && return setfield!(node, :data, x)
    d = getfield(node, :data)
    return setfield!(d, name, x)
end

const AbstractSyntaxNode = TreeNode{<:AbstractSyntaxData}

# There's two ways this can arise:
# 1. From parsing a source file.
# 2. Programmatically
struct SyntaxData <: AbstractSyntaxData
    head::SyntaxHead
    source::Union{Nothing,SourceFile}
    raw::Union{Nothing,GreenNode{SyntaxHead}}
    position::Int
    val::Any
end

function SyntaxData(source::SourceFile, raw::GreenNode{SyntaxHead},
                    position::Int, val::Any)
    SyntaxData(head(raw), source, raw, position, val)
end

# SyntaxData constructed "in code"
function SyntaxData(head::SyntaxHead, val::Any; srcref=nothing)
    if isnothing(srcref)
        SyntaxData(head, nothing, nothing, 0, val)
    else
        SyntaxData(head, srcref.source, srcref.raw, srcref.position, val)
    end
end

function SyntaxData(kind::Kind, val::Any; kws...)
    SyntaxData(SyntaxHead(kind, EMPTY_FLAGS), val; kws...)
end

# Design musings
#
# getproperty overloading for virtual fields
#
# Yeeeah this is a very inefficient way to do it. It asks a lot of the compiler
# to elide all the branches here. *Especially* eliding the branch on the kind
# seems difficult.
# Pattern matching ftw tbh
#
# function Base.getproperty(node::SyntaxNode, name::Symbol)
#     # Uuugh yea we can't have this (fixme).  Maybe virtual underscore-named fields?
#     name === :parent   && return getfield(node, :parent)
#     name === :children && return getfield(node, :children)
#     name === :head     && return getfield(node, :data).head
#     name === :source   && return getfield(node, :data).source
#     name === :raw      && return getfield(node, :data).raw
#     name === :position && return getfield(node, :data).position
#     name === :val      && return getfield(node, :data).val
#
#     h = head(node)
#     k = kind(node)
#     if name === :name
#         if k == K"call"
#             if is_infix_op_call(h) || is_postfix_op_call(h)
#                 node[2]
#             else
#                 node[1]
#             end
#         end
#     elseif name === :args
#     end
# end
#
# Could SyntaxNode be a sum type? And if it were, could we have it as optimal
# as it currently is? Weell... it'd probably be less optimal because things
# like the try node have many children. So the sizeof the sum type would be
# quite large.  Also trivia really fucks us over and we can't use sum types for
# GreenNode at the very least.
#
# getproperty though, maybe?

"""
    SyntaxNode(source::SourceFile, raw::GreenNode{SyntaxHead};
               keep_parens=false, position::Integer=1)

An AST node with a similar layout to `Expr`. Typically constructed from source
text by calling one of the parser API functions such as [`parseall`](@ref)
"""
const SyntaxNode = TreeNode{SyntaxData}

function SyntaxNode(head::Union{Kind,SyntaxHead}, children::Vector{SyntaxNode};
                    srcref=nothing)
    SyntaxNode(nothing, children, SyntaxData(head, nothing; srcref=srcref))
end

function SyntaxNode(head::Union{Kind,SyntaxHead}, val::Any;
                    srcref=nothing)
    SyntaxNode(nothing, nothing, SyntaxData(head, val; srcref=srcref))
end

function SyntaxNode(head::Union{Kind,SyntaxHead}, srcref::SyntaxNode,
                    children::Vector{SyntaxNode})
    SyntaxNode(nothing, children, SyntaxData(head, nothing; srcref=srcref))
end

function SyntaxNode(head::Union{Kind,SyntaxHead}, srcref::SyntaxNode, val::Any)
    SyntaxNode(nothing, nothing, SyntaxData(head, val; srcref=srcref))
end

function SyntaxNode(source::SourceFile, raw::GreenNode{SyntaxHead};
                    keep_parens=false, position::Integer=1)
    GC.@preserve source begin
        raw_offset, txtbuf = _unsafe_wrap_substring(source.code)
        offset = raw_offset - source.byte_offset
        _to_SyntaxNode(source, txtbuf, offset, raw, convert(Int, position), keep_parens)
    end
end

function _to_SyntaxNode(source::SourceFile, txtbuf::Vector{UInt8}, offset::Int,
                        raw::GreenNode{SyntaxHead},
                        position::Int, keep_parens::Bool)
    if !haschildren(raw)
        # Here we parse the values eagerly rather than representing them as
        # strings. Maybe this is good. Maybe not.
        valrange = position:position + span(raw) - 1
        val = parse_julia_literal(txtbuf, head(raw), valrange .+ offset)
        return SyntaxNode(nothing, nothing, SyntaxData(source, raw, position, val))
    else
        cs = SyntaxNode[]
        pos = position
        for (i,rawchild) in enumerate(children(raw))
            # FIXME: Allowing trivia is_error nodes here corrupts the tree layout.
            if !is_trivia(rawchild) || is_error(rawchild)
                push!(cs, _to_SyntaxNode(source, txtbuf, offset, rawchild, pos, keep_parens))
            end
            pos += Int(rawchild.span)
        end
        if !keep_parens && kind(raw) == K"parens" && length(cs) == 1
            return cs[1]
        end
        if kind(raw) == K"wrapper" && length(cs) == 1
            return cs[1]
        end
        node = SyntaxNode(nothing, cs, SyntaxData(source, raw, position, nothing))
        for c in cs
            c.parent = node
        end
        return node
    end
end

haschildren(node::TreeNode) = node.children !== nothing
children(node::TreeNode) = (c = node.children; return c === nothing ? () : c)
numchildren(node::TreeNode) = (isnothing(node.children) ? 0 : length(node.children))


"""
    head(x)

Get the [`SyntaxHead`](@ref) of a node of a tree or other syntax-related data
structure.
"""
head(node::AbstractSyntaxNode) = head(node.data)

span(node::AbstractSyntaxNode) = span(node.data)

first_byte(node::AbstractSyntaxNode) = first_byte(node.data)
last_byte(node::AbstractSyntaxNode)  = last_byte(node.data)


# TODO: Deprecate these as they rely on the field names of AbstractSyntaxData?
head(data::AbstractSyntaxData) = head(data.raw)
span(data::AbstractSyntaxData) = span(data.raw)
first_byte(data::AbstractSyntaxData) = data.position
last_byte(data::AbstractSyntaxData)  = data.position + span(data) - 1
source_line(data::AbstractSyntaxData) = source_line(data.source, data.position)
source_location(data::AbstractSyntaxData) = source_location(data.source, data.position)

head(data::SyntaxData) = data.head
span(data::SyntaxData) = isnothing(data.raw) ? 0 : span(data.raw)
first_byte(data::SyntaxData) = data.position
last_byte(data::SyntaxData)  = data.position + span(data) - 1

"""
    sourcetext(node)

Get the full source text of a node.
"""
function sourcetext(node::AbstractSyntaxNode)
    view(node.source, range(node))
end

function Base.range(node::AbstractSyntaxNode)
    (node.position-1) .+ (1:span(node))
end

source_line(node::AbstractSyntaxNode) = source_line(node.data)
source_location(node::AbstractSyntaxNode) = source_location(node.data)

filename(node::AbstractSyntaxNode) = filename(node.data)
function filename(data::SyntaxData)
    isnothing(data.source) ? "" : data.source.filename
end

function source_location(data::SyntaxData)
    return isnothing(data.source) ? (0,0) :
           source_location(data.source, data.position)
end

function _show_syntax_node(io, current_filename, node::AbstractSyntaxNode,
                           indent, show_byte_offsets)
    fname = filename(node)
    line, col = source_location(node)
    posstr = "$(lpad(line, 4)):$(rpad(col,3))│"
    if show_byte_offsets
        posstr *= "$(lpad(first_byte(node),6)):$(rpad(last_byte(node),6))│"
    end
    val = node.val
    nodestr = haschildren(node) ? "[$(untokenize(head(node)))]" :
              isa(val, Symbol) ? string(val) : repr(val)
    treestr = string(indent, nodestr)
    # Add filename if it's changed from the previous node
    if fname != current_filename[]
        #println(io, "# ", fname)
        treestr = string(rpad(treestr, 40), "│$fname")
        current_filename[] = fname
    end
    println(io, posstr, treestr)
    if haschildren(node)
        new_indent = indent*"  "
        for n in children(node)
            _show_syntax_node(io, current_filename, n, new_indent, show_byte_offsets)
        end
    end
end

function _show_syntax_node_sexpr(io, node::AbstractSyntaxNode)
    if !haschildren(node)
        if is_error(node)
            print(io, "(", untokenize(head(node)), ")")
        else
            val = node.val
            print(io, val isa Symbol ? string(val) : repr(val))
        end
    else
        print(io, "(", untokenize(head(node)))
        first = true
        for n in children(node)
            print(io, ' ')
            _show_syntax_node_sexpr(io, n)
            first = false
        end
        print(io, ')')
    end
end

function Base.show(io::IO, ::MIME"text/plain", node::AbstractSyntaxNode; show_byte_offsets=false)
    println(io, "line:col│$(show_byte_offsets ? " byte_range  │" : "") tree                                   │ file_name")
    _show_syntax_node(io, Ref{Union{Nothing,String}}(nothing), node, "", show_byte_offsets)
end

function Base.show(io::IO, ::MIME"text/x.sexpression", node::AbstractSyntaxNode)
    _show_syntax_node_sexpr(io, node)
end

function Base.show(io::IO, node::AbstractSyntaxNode)
    _show_syntax_node_sexpr(io, node)
end

function Base.push!(node::SN, child::SN) where SN<:AbstractSyntaxNode
    if !haschildren(node)
        error("Cannot add children")
    end
    args = children(node)
    push!(args, child)
end

function Base.copy(node::TreeNode)
    # copy the container but not the data (ie, deep copy the tree, shallow copy the data). copy(::Expr) is similar
    # copy "un-parents" the top-level `node` that you're copying
    newnode = typeof(node)(nothing, haschildren(node) ? typeof(node)[] : nothing, copy(node.data))
    for child in children(node)
        newchild = copy(child)
        newchild.parent = newnode
        push!(newnode, newchild)
    end
    return newnode
end

# shallow-copy the data
Base.copy(data::SyntaxData) = SyntaxData(data.head, data.source, data.raw, data.position, data.val)

function build_tree(::Type{SyntaxNode}, stream::ParseStream;
                    filename=nothing, first_line=1, keep_parens=false, kws...)
    green_tree = build_tree(GreenNode, stream; kws...)
    source = SourceFile(stream, filename=filename, first_line=first_line)
    SyntaxNode(source, green_tree, position=first_byte(stream), keep_parens=keep_parens)
end

#-------------------------------------------------------------------------------
# Tree utilities

"""
    child(node, i1, i2, ...)

Get child at a tree path. If indexing accessed children, it would be
`node[i1][i2][...]`
"""
function child(node, path::Integer...)
    n = node
    for index in path
        n = children(n)[index]
    end
    return n
end

function setchild!(node::SyntaxNode, path, x)
    n1 = child(node, path[1:end-1]...)
    n1.children[path[end]] = x
end

# We can overload multidimensional Base.getindex / Base.setindex! for node
# types.
#
# The justification for this is to view a tree as a multidimensional ragged
# array, where descending depthwise into the tree corresponds to dimensions of
# the array.
#
# However... this analogy is only good for complete trees at a given depth (=
# dimension). But the syntax is oh-so-handy!
function Base.getindex(node::Union{SyntaxNode,GreenNode}, path::Int...)
    child(node, path...)
end
function Base.lastindex(node::Union{SyntaxNode,GreenNode})
    length(children(node))
end

function Base.setindex!(node::SyntaxNode, x::SyntaxNode, path::Int...)
    setchild!(node, path, x)
end

"""
Get absolute position and span of the child of `node` at the given tree `path`.
"""
function child_position_span(node::GreenNode, path::Int...)
    n = node
    p = 1
    for index in path
        cs = children(n)
        for i = 1:index-1
            p += span(cs[i])
        end
        n = cs[index]
    end
    return n, p, n.span
end

function child_position_span(node::SyntaxNode, path::Int...)
    n = child(node, path...)
    n, n.position, span(n)
end

function highlight(io::IO, node::SyntaxNode; kws...)
    highlight(io, node.source, range(node); kws...)
end

function highlight(io::IO, source::SourceFile, node::GreenNode, path::Int...; kws...)
    _, p, span = child_position_span(node, path...)
    q = p + span - 1
    highlight(io, source, p:q; kws...)
end
