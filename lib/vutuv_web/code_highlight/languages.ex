defmodule VutuvWeb.CodeHighlight.Languages do
  @moduledoc """
  The language registry behind `VutuvWeb.CodeHighlight`: what a code fence's
  info string names, and the handful of facts the lexer needs to colour it.

  Each entry is deliberately shallow — how comments and strings are delimited,
  which words are keywords, which sigil character starts a literal. That is
  enough for the four things the eye actually reads in a code block (comments,
  strings, numbers, keywords) and it means a new language costs a keyword list
  rather than a parser. Anything the registry does not know still gets its
  label; it just renders as plain text.

  Three `:family` values: `:code` (the default scanner), `:markup` (tags and
  attributes, for HTML/XML and friends) — see `VutuvWeb.CodeHighlight.Lexer` —
  and `:none`, "label it but leave the body alone", which is how a `diff` fence
  stays the property of `VutuvWeb.CodeHighlight.Diff.render/1`.

  Fields, all optional:

    * `:label` — the display name shown in the corner of the block
    * `:aliases` — further fence words that mean this language
    * `:family` — `:code` (default), `:markup` or `:none`
    * `:line` — line-comment openers, e.g. `["//", "#"]`
    * `:block` — `{opener, closer}` for a block comment
    * `:quotes` — string delimiters that end at their own character or, for
      `?"`/`?'`, at the end of the line (so one stray quote cannot paint the
      rest of the block); a backtick may span lines
    * `:triples` — triple-quoted string delimiters, which may span lines
    * `:prefixed` — characters that start a literal when a word follows
      (`:atom`, `@attribute`, `$var`)
    * `:keywords` / `:builtins` — the two word lists (types, constants and
      language-provided names go in `:builtins`)
    * `:word_extra` / `:word_suffix` — extra characters inside / at the end of
      an identifier (Clojure's `-`, Elixir's `?` and `!`)
    * `:ci` — look keywords up case-insensitively (SQL, Dockerfile)
  """

  @default %{
    label: nil,
    aliases: [],
    family: :code,
    line: [],
    block: nil,
    quotes: [],
    triples: [],
    prefixed: [],
    keywords: [],
    builtins: [],
    word_extra: [],
    word_suffix: [],
    ci: false
  }

  # The fence words that mean "this is not a language, do not label it".
  @plain ~w(text plain plaintext none txt output console-output raw)

  @c_comments %{line: ["//"], block: {"/*", "*/"}}

  @c_keywords ~w(break case const continue default do else enum extern for goto
                 if inline return sizeof static struct switch typedef union
                 volatile while)

  @c_types ~w(bool char double float int long short signed unsigned void
              size_t NULL true false)

  @js_keywords ~w(as async await break case catch class const continue debugger
                  default delete do else export extends finally for from
                  function get if import in instanceof let new of return set
                  static super switch this throw try typeof var void while with
                  yield)

  @js_builtins ~w(Array Boolean Date Error JSON Map Math Number Object Promise
                  RegExp Set String Symbol console document globalThis null
                  true false undefined window NaN Infinity)

  @sql_keywords ~w(add all alter and as asc begin between by cascade case cast
                   check column commit constraint create cross default delete
                   desc distinct drop else end exists foreign from full group
                   having if in index inner insert intersect into is join key
                   left like limit not null offset on or order outer primary
                   references replace returning right rollback select set table
                   then transaction union unique update using values view when
                   where with)

  @languages %{
    "elixir" => %{
      label: "Elixir",
      aliases: ~w(ex exs),
      line: ["#"],
      quotes: [?", ?'],
      triples: [~s("""), "'''"],
      prefixed: [?:, ?@],
      word_suffix: [??, ?!],
      keywords: ~w(after and case catch cond def defdelegate defexception
                   defguard defguardp defimpl defmacro defmacrop defmodule
                   defoverridable defp defprotocol defstruct do else end fn for
                   if import in not or quote raise receive require rescue try
                   unless unquote use when with),
      builtins: ~w(true false nil self __MODULE__ __DIR__ __ENV__ __CALLER__)
    },
    "erlang" => %{
      label: "Erlang",
      aliases: ~w(erl hrl),
      line: ["%"],
      quotes: [?", ?'],
      prefixed: [??],
      keywords: ~w(after begin case catch cond end fun if let of receive try
                   when andalso orelse band bor bxor bnot div rem not and or
                   xor),
      builtins: ~w(true false undefined ok error module export spec type record
                   behaviour)
    },
    "javascript" => %{
      label: "JavaScript",
      aliases: ~w(js node mjs cjs jsx),
      line: @c_comments.line,
      block: @c_comments.block,
      quotes: [?", ?', ?`],
      keywords: @js_keywords,
      builtins: @js_builtins
    },
    "typescript" => %{
      label: "TypeScript",
      aliases: ~w(ts tsx),
      line: @c_comments.line,
      block: @c_comments.block,
      quotes: [?", ?', ?`],
      keywords: @js_keywords ++ ~w(abstract declare enum implements interface
                                   is keyof namespace private protected public
                                   readonly type),
      builtins: @js_builtins ++ ~w(any never number string boolean unknown void)
    },
    "python" => %{
      label: "Python",
      aliases: ~w(py python3 py3),
      line: ["#"],
      quotes: [?", ?'],
      triples: [~s("""), "'''"],
      prefixed: [?@],
      keywords: ~w(and as assert async await break class continue def del elif
                   else except finally for from global if import in is lambda
                   nonlocal not or pass raise return try while with yield
                   match case),
      builtins: ~w(True False None self cls bool bytes dict float int len list
                   object print range set str super tuple type)
    },
    "ruby" => %{
      label: "Ruby",
      aliases: ~w(rb gemfile rake),
      line: ["#"],
      quotes: [?", ?'],
      prefixed: [?:, ?@, ?$],
      word_suffix: [??, ?!],
      keywords: ~w(alias and begin break case class def defined do else elsif
                   end ensure for if in module next not or redo rescue retry
                   return self super then unless until when while yield),
      builtins: ~w(attr_accessor attr_reader attr_writer false nil private
                   protected public puts require require_relative true)
    },
    "php" => %{
      label: "PHP",
      aliases: ~w(php8),
      line: ["//", "#"],
      block: {"/*", "*/"},
      quotes: [?", ?'],
      prefixed: [?$],
      keywords: ~w(abstract and array as break case catch class clone const
                   continue declare default do echo else elseif enum extends
                   final finally fn for foreach function global if implements
                   include instanceof interface match namespace new or print
                   private protected public readonly require return static
                   switch throw trait try use var while xor yield),
      builtins: ~w(true false null self parent int float string bool void
                   iterable object mixed)
    },
    "java" => %{
      label: "Java",
      line: ["//"],
      block: {"/*", "*/"},
      quotes: [?", ?'],
      prefixed: [?@],
      keywords: ~w(abstract assert break case catch class const continue default
                   do else enum extends final finally for goto if implements
                   import instanceof interface native new package private
                   protected public record return sealed static strictfp super
                   switch synchronized this throw throws transient try var
                   volatile while yield),
      builtins: ~w(boolean byte char double float int long short void String
                   Integer Boolean Double List Map Object true false null)
    },
    "kotlin" => %{
      label: "Kotlin",
      aliases: ~w(kt kts),
      line: ["//"],
      block: {"/*", "*/"},
      quotes: [?", ?'],
      prefixed: [?@],
      keywords: ~w(as break by class companion const continue crossinline data
                   do else enum external final finally for fun get if import in
                   infix init inline interface internal is lateinit noinline
                   object open operator out override package private protected
                   public reified return sealed set super suspend this throw
                   try typealias val var vararg when where while),
      builtins: ~w(Any Boolean Double Float Int List Long Map Nothing Set String
                   Unit false null true it)
    },
    "swift" => %{
      label: "Swift",
      line: ["//"],
      block: {"/*", "*/"},
      quotes: [?"],
      prefixed: [?@],
      keywords: ~w(as associatedtype async await break case catch class continue
                   default defer deinit do else enum extension fallthrough false
                   fileprivate for func guard if import in init inout internal
                   is let mutating nil open operator private protocol public
                   repeat rethrows return self static struct subscript super
                   switch throw throws true try typealias var where while),
      builtins: ~w(Any Array Bool Character Data Dictionary Double Error Float
                   Int Optional Set String Void)
    },
    "go" => %{
      label: "Go",
      aliases: ~w(golang),
      line: ["//"],
      block: {"/*", "*/"},
      quotes: [?", ?', ?`],
      keywords: ~w(break case chan const continue default defer else fallthrough
                   for func go goto if import interface map package range return
                   select struct switch type var),
      builtins: ~w(append bool byte cap close complex copy delete error false
                   float32 float64 int int8 int16 int32 int64 iota len make map
                   new nil panic print println recover rune string true uint
                   uintptr)
    },
    "rust" => %{
      label: "Rust",
      aliases: ~w(rs),
      line: ["//"],
      block: {"/*", "*/"},
      quotes: [?", ?'],
      prefixed: [],
      keywords: ~w(as async await break const continue crate dyn else enum
                   extern fn for if impl in let loop match mod move mut pub ref
                   return self static struct super trait type unsafe use where
                   while),
      builtins: ~w(bool char f32 f64 i8 i16 i32 i64 isize u8 u16 u32 u64 usize
                   str String Vec Option Some None Result Ok Err Box true false
                   println panic)
    },
    "c" => %{
      label: "C",
      aliases: ~w(h),
      line: @c_comments.line,
      block: @c_comments.block,
      quotes: [?", ?'],
      prefixed: [?#],
      keywords: @c_keywords ++ ~w(auto register restrict),
      builtins: @c_types
    },
    "cpp" => %{
      label: "C++",
      aliases: ~w(c++ cc cxx hpp hxx),
      line: @c_comments.line,
      block: @c_comments.block,
      quotes: [?", ?'],
      prefixed: [?#],
      keywords:
        @c_keywords ++
          ~w(catch class concept constexpr delete explicit friend namespace new
             noexcept nullptr operator override private protected public
             template this throw try typename using virtual),
      builtins: @c_types ++ ~w(std string vector map auto)
    },
    "csharp" => %{
      label: "C#",
      aliases: ~w(cs c#),
      line: @c_comments.line,
      block: @c_comments.block,
      quotes: [?", ?'],
      keywords: ~w(abstract as async await base break case catch checked class
                   const continue default delegate do else enum event explicit
                   extern finally fixed for foreach get goto if implicit in
                   interface internal is lock namespace new operator out
                   override params private protected public readonly ref return
                   sealed set sizeof stackalloc static struct switch this throw
                   try typeof unchecked unsafe using var virtual void while
                   yield record),
      builtins: ~w(bool byte char decimal double float int long object sbyte
                   short string uint ulong ushort true false null List
                   Dictionary Task)
    },
    "scala" => %{
      label: "Scala",
      line: ["//"],
      block: {"/*", "*/"},
      quotes: [?", ?'],
      triples: [~s(""")],
      prefixed: [?@],
      keywords: ~w(abstract case catch class def do else extends final finally
                   for forSome given if implicit import lazy match new object
                   override package private protected return sealed super this
                   throw trait try type val var while with yield),
      builtins: ~w(Any Boolean Double Float Int List Long Map Nil None Option
                   Seq Set Some String Unit false null true)
    },
    "haskell" => %{
      label: "Haskell",
      aliases: ~w(hs),
      line: ["--"],
      block: {"{-", "-}"},
      quotes: [?", ?'],
      word_extra: [?'],
      keywords: ~w(case class data default deriving do else foreign if import
                   in infix infixl infixr instance let module newtype of then
                   type where),
      builtins: ~w(Bool Char Double Either False Float Int Integer IO Just Left
                   Maybe Nothing Right String True map filter foldr)
    },
    "clojure" => %{
      label: "Clojure",
      aliases: ~w(clj cljs edn),
      line: [";"],
      quotes: [?"],
      prefixed: [?:],
      word_extra: [?-, ?*, ?>, ?<, ?=],
      word_suffix: [??, ?!],
      keywords: ~w(def defn defmacro defmulti defmethod defprotocol defrecord
                   defstruct do fn if let letfn loop ns quote recur require
                   throw try var when when-not while),
      builtins: ~w(nil true false first rest cons conj assoc dissoc map filter
                   reduce apply str println atom swap! reset!)
    },
    "perl" => %{
      label: "Perl",
      aliases: ~w(pl pm),
      line: ["#"],
      quotes: [?", ?'],
      prefixed: [?$, ?@, ?%],
      keywords: ~w(and cmp continue do else elsif eq for foreach ge gt if last
                   le local lt my ne next no not or our package redo ref return
                   sub unless until use wantarray while),
      builtins: ~w(defined delete die exists join keys length print printf push
                   scalar shift sort split sprintf undef unshift values warn)
    },
    "lua" => %{
      label: "Lua",
      line: ["--"],
      quotes: [?", ?'],
      keywords: ~w(and break do else elseif end for function goto if in local
                   not or repeat return then until while),
      builtins: ~w(false nil true self ipairs pairs print require setmetatable
                   tonumber tostring type)
    },
    "dart" => %{
      label: "Dart",
      line: ["//"],
      block: {"/*", "*/"},
      quotes: [?", ?'],
      prefixed: [?@],
      keywords: ~w(abstract as assert async await break case catch class const
                   continue covariant default deferred do dynamic else enum
                   export extends extension external factory final finally for
                   get if implements import in interface is late library mixin
                   new on operator part required rethrows return set show static
                   super switch sync this throw try typedef var while with
                   yield),
      builtins: ~w(bool double false int List Map null num Set String true void
                   Future Stream Widget)
    },
    "r" => %{
      label: "R",
      line: ["#"],
      quotes: [?", ?'],
      word_extra: [?.],
      keywords: ~w(break else for function if in next repeat return while),
      builtins: ~w(FALSE Inf NA NaN NULL TRUE c data.frame factor function
                   library list matrix vector)
    },
    "zig" => %{
      label: "Zig",
      line: ["//"],
      quotes: [?", ?'],
      keywords: ~w(align allowzero and asm async await break catch comptime
                   const continue defer else enum errdefer error export extern
                   fn for if inline noalias or orelse packed pub resume return
                   struct suspend switch test threadlocal try union unreachable
                   usingnamespace var volatile while),
      builtins: ~w(bool f32 f64 i8 i16 i32 i64 u8 u16 u32 u64 usize isize void
                   null true false undefined anytype std)
    },
    "sql" => %{
      label: "SQL",
      aliases: ~w(postgres postgresql psql mysql sqlite mariadb),
      line: ["--"],
      block: {"/*", "*/"},
      quotes: [?', ?"],
      ci: true,
      keywords: @sql_keywords,
      builtins: ~w(bigint boolean bytea char date decimal float int integer
                   interval json jsonb numeric real serial smallint text time
                   timestamp uuid varchar true false null count sum avg min max)
    },
    "bash" => %{
      label: "Shell",
      aliases: ~w(sh shell zsh console terminal shell-session bashrc),
      line: ["#"],
      quotes: [?", ?', ?`],
      prefixed: [?$],
      keywords: ~w(case do done elif else esac fi for function if in local
                   return select then time until while),
      builtins: ~w(alias cat cd chmod cp curl echo env exit export git grep
                   kill ls mkdir mv printf pwd read rm sed set source ssh sudo
                   tar test touch unset wget)
    },
    "powershell" => %{
      label: "PowerShell",
      aliases: ~w(ps1 pwsh),
      line: ["#"],
      block: {"<#", "#>"},
      quotes: [?", ?'],
      prefixed: [?$],
      word_extra: [?-],
      ci: true,
      keywords: ~w(begin break catch continue data do dynamicparam else elseif
                   end exit filter finally for foreach function if in param
                   process return switch throw trap try until while),
      builtins: ~w(Get-ChildItem Get-Content Set-Content Write-Host Write-Output
                   New-Item Remove-Item Select-Object Where-Object ForEach-Object
                   true false null)
    },
    "yaml" => %{
      label: "YAML",
      aliases: ~w(yml),
      line: ["#"],
      quotes: [?", ?'],
      builtins: ~w(true false yes no on off null ~)
    },
    "json" => %{
      label: "JSON",
      aliases: ~w(jsonc json5),
      quotes: [?"],
      builtins: ~w(true false null)
    },
    "toml" => %{
      label: "TOML",
      line: ["#"],
      quotes: [?", ?'],
      builtins: ~w(true false)
    },
    "ini" => %{
      label: "INI",
      aliases: ~w(cfg conf properties editorconfig),
      line: ["#", ";"],
      quotes: [?", ?'],
      ci: true,
      builtins: ~w(true false yes no on off)
    },
    "css" => %{
      label: "CSS",
      block: {"/*", "*/"},
      quotes: [?", ?'],
      prefixed: [?@, ?#],
      word_extra: [?-],
      builtins: ~w(inherit initial none unset auto important var calc rgb rgba
                   hsl url)
    },
    "scss" => %{
      label: "SCSS",
      aliases: ~w(sass less),
      line: ["//"],
      block: {"/*", "*/"},
      quotes: [?", ?'],
      prefixed: [?$, ?@, ?#],
      word_extra: [?-],
      keywords: ~w(each else extend for function if import include mixin return
                   use while),
      builtins: ~w(inherit initial none unset auto important var calc rgb rgba
                   hsl url)
    },
    "dockerfile" => %{
      label: "Dockerfile",
      aliases: ~w(docker containerfile),
      line: ["#"],
      quotes: [?", ?'],
      prefixed: [?$],
      ci: true,
      keywords: ~w(add arg cmd copy entrypoint env expose from healthcheck label
                   maintainer onbuild run shell stopsignal user volume workdir),
      builtins: ~w(as)
    },
    "makefile" => %{
      label: "Makefile",
      aliases: ~w(make mk),
      line: ["#"],
      quotes: [?", ?'],
      prefixed: [?$],
      keywords: ~w(define else endef endif export ifdef ifeq ifndef ifneq
                   include override unexport vpath)
    },
    "nginx" => %{
      label: "nginx",
      line: ["#"],
      quotes: [?", ?'],
      prefixed: [?$],
      word_extra: [?_],
      keywords: ~w(http server location upstream events include listen
                   proxy_pass return rewrite root server_name ssl_certificate
                   try_files)
    },
    "hcl" => %{
      label: "Terraform",
      aliases: ~w(terraform tf tfvars),
      line: ["#", "//"],
      block: {"/*", "*/"},
      quotes: [?", ?'],
      keywords: ~w(data locals module output provider resource terraform
                   variable for_each count depends_on),
      builtins: ~w(true false null bool list map number object set string var
                   local each)
    },
    "graphql" => %{
      label: "GraphQL",
      aliases: ~w(gql),
      line: ["#"],
      quotes: [?"],
      triples: [~s(""")],
      prefixed: [?$, ?@],
      keywords: ~w(directive enum extend fragment implements input interface
                   mutation on query scalar schema subscription type union),
      builtins: ~w(Boolean Float ID Int String true false null)
    },
    "html" => %{
      label: "HTML",
      aliases: ~w(htm xhtml vue svelte),
      family: :markup
    },
    "heex" => %{
      label: "HEEx",
      aliases: ~w(eex leex),
      family: :markup
    },
    "xml" => %{
      label: "XML",
      aliases: ~w(svg rss atom xsl xslt plist),
      family: :markup
    },
    # Labelled here so the corner reads "Diff", but the body is not tokenized:
    # `VutuvWeb.CodeHighlight.Diff.render/1` runs after us and renders it
    # as real added / removed rows (issue #1108).
    "diff" => %{
      label: "Diff",
      aliases: ~w(patch udiff),
      family: :none
    },
    "markdown" => %{
      label: "Markdown",
      aliases: ~w(md mdx)
    },
    "vim" => %{
      label: "Vim script",
      aliases: ~w(viml vimscript),
      line: ["\""],
      quotes: [?'],
      prefixed: [?$, ?@],
      keywords: ~w(call echo elseif else endfor endfunction endif for function
                   if let return set setlocal while)
    }
  }

  # A case-insensitive language is looked up on the downcased word, so its own
  # lists have to be downcased too — otherwise `Get-ChildItem` would never match.
  @registry (for {slug, config} <- @languages, into: %{} do
               config = Map.merge(@default, config)
               fold = if config.ci, do: &String.downcase/1, else: & &1

               config = %{
                 config
                 | keywords: MapSet.new(config.keywords, fold),
                   builtins: MapSet.new(config.builtins, fold)
               }

               {slug, config}
             end)

  @by_name for {slug, config} <- @registry,
               name <- [slug | config.aliases],
               into: %{},
               do: {name, slug}

  @doc """
  The language configuration for a normalized fence word, or `nil` when the
  registry does not know it (the block then gets its label and no colouring).
  """
  def get(name) when is_binary(name) do
    case Map.fetch(@by_name, name) do
      {:ok, slug} -> Map.fetch!(@registry, slug)
      :error -> nil
    end
  end

  @doc """
  The canonical slug for a fence word, or the word itself when unknown — this
  is what becomes the `language-*` class on the `<code>` element.
  """
  def slug(name) when is_binary(name), do: Map.get(@by_name, name, name)

  @doc "True for the fence words that mean \"no language\", which get no label."
  def plain?(name) when is_binary(name), do: name in @plain

  @doc "Every fence word the registry answers to. For tests and documentation."
  def names, do: Map.keys(@by_name)

  @doc """
  Every fence word the composer might meet, mapped to the label the published
  block will show for it — and the "no language" words mapped to `""`, the
  signal that such a block gets no label there either.

  `VutuvWeb.UI.markdown_editor/1` serializes this map onto the editor root
  (`data-mde-langs`) so the composer's code-block preview (issues #1108, #1137,
  #1138) names a block the way the rendered post will, without a second copy of
  this registry living in JavaScript.
  """
  def editor_labels do
    labels =
      for {name, slug} <- @by_name, into: %{} do
        {name, Map.fetch!(@registry, slug).label}
      end

    Enum.reduce(@plain, labels, &Map.put(&2, &1, ""))
  end
end
