# Formatting text with Markdown

Wherever you write more than a line on vutuv, we understand Markdown: in posts
and replies, in messages, in the descriptions of your work experience and
education, in job postings and on organization pages. Markdown is not a
programming language, it is a handful of characters you can learn in five
minutes: two asterisks for bold, a hyphen for a list item.

In the post editor you rarely have to type any of it. It shows you the result
as you write and has buttons for bold, italics, lists and the rest. If you
prefer typing the characters yourself, the **MD** button switches to the source
view. This page is written for both kinds of writer, and everything on it is
real: every example below is rendered exactly the way it will look in your
post.

## Bold, italics, strikethrough

| You write | You get |
| --- | --- |
| `**important**` | **important** |
| `*emphasis*` | *emphasis* |
| `***both***` | ***both*** |
| `~~dropped~~` | ~~dropped~~ |
| `` `a snippet` `` | `a snippet` |

An underscore does the same job as an asterisk: `_emphasis_` and
`__important__` work too. When an asterisk really is meant to be an asterisk,
put a backslash in front of it: `\*like this\*` comes out as \*like this\*.

## Paragraphs and line breaks

A blank line starts a new paragraph. That is the most reliable way to give a
text some shape.

A single line break inside a paragraph is *not* kept in a **post**: the text
flows on, the way it does in a book. That is deliberate, because otherwise
every break some other program left behind when you copied the text would show
up as a hard break in your post. In **messages** it is the other way round:
there, every new line really does break, because chat is written in short
lines.

## Links, mentions and hashtags

An address starting with `http://` or `https://` becomes a link on its own. We
shorten very long addresses in the display so they cannot blow up a narrow
column; clicking one still takes you to the full target.

When the wording of the link matters, put the text in square brackets and the
address in round ones after it:

```markdown
[the member directory](https://vutuv.de/system/members)
```

[the member directory](https://vutuv.de/system/members)

An `@` in front of a username links to that profile, as long as the member
exists. A name we do not know stays plain text, so a link never lands
nowhere. The same syntax reaches people elsewhere in the fediverse if you name
their server: `@name@server.social` links there.

A `#` in front of a word links to that tag's page, as long as the tag belongs
to somebody on vutuv. So `#elixir` takes the reader to the members who know
Elixir.

## Lists

A hyphen and a space make a bullet. Two spaces of indentation make a sublevel.

```markdown
- Interviews
- Onboarding
  - First week
  - First month
```

- Interviews
- Onboarding
  - First week
  - First month

Numbered lists take a digit and a full stop:

```markdown
1. Post the job
2. Talk to people
3. Make an offer
```

1. Post the job
2. Talk to people
3. Make an offer

Checkbox lists (`- [ ]`) are not supported. They come out as what they are:
square brackets in the text.

## Headings

One to six hashes at the start of a line, then a space:

```markdown
## Where we started
### One detail about it
```

In posts, headings render as bold body text rather than at headline size. A
post is short enough that a big heading would visually flatten it. The
structure is still there for search engines and for anyone having the post read
out to them.

## Quotations

A greater-than sign at the start of a line sets the text off as a quote:

```markdown
> We are hiring two developers.
```

> We are hiring two developers.

## Horizontal rule

Three hyphens alone on a line draw a line across:

```markdown
---
```

---

## Code

Single commands, file names or field names go in plain backticks: `` `mix test` ``
becomes `mix test`. Nothing else happens inside those backticks, so a `*` stays
a `*`.

Longer snippets go between two lines of three backticks. Write the language
right after the first line and the block gets its name in the corner and its
code in colour:

````markdown
```elixir
# a greeting
IO.puts("Hello #{name}")
```
````

```elixir
# a greeting
IO.puts("Hello #{name}")
```

We know around 45 languages, among them Elixir, Erlang, Ruby, Python, PHP,
JavaScript, TypeScript, Go, Rust, Java, Kotlin, Swift, C, C++, C#, SQL, HTML,
CSS, YAML, JSON, Bash and Dockerfile. A language we do not know does no harm:
the block still gets its label, it just gets no colours. To have a block carry
no label at all, write `text` after the backticks.

All of this happens on our server. Your browser downloads not one line of extra
code for the colouring, and a reader who never sees a code block pays nothing
for it.

### Naming the file

A snippet often only makes sense once you know which file it came from. Write
the name after a colon:

````markdown
```php:app/Providers/AppServiceProvider.php
<?php
$a = 1;
```
````

```php:app/Providers/AppServiceProvider.php
<?php
$a = 1;
```

If you prefer the long form, write
`title="app/Providers/AppServiceProvider.php"` instead. Both produce the same
block. You only need the long form when the title contains a space.

### Showing a change

The `diff` language shows what changed. Lines starting with `-` count as
removed, lines starting with `+` as added:

````markdown
```diff
- $port = 4000
+ $port = 4001
```
````

```diff
- $port = 4000
+ $port = 4001
```

A diff says nothing about the language the changed code is written in, though,
which is why it used to stay colourless. Name the language after the colon and
you get both: the change is marked and the code is coloured.

````markdown
```diff:elixir
  def start(_type, _args) do
-   Logger.info("old")
+   Logger.info("new")
  end
```
````

```diff:elixir
  def start(_type, _args) do
-   Logger.info("old")
+   Logger.info("new")
  end
```

Written out in full that is `lang="elixir"`. A file name still fits alongside
it.

## Tables

Vertical bars separate the columns, the second row of hyphens separates the
header from the rest:

```markdown
| Role | Location | Open since |
| --- | --- | --- |
| Backend | Remote | March |
| Design | Hamburg | May |
```

| Role | Location | Open since |
| --- | --- | --- |
| Backend | Remote | March |
| Design | Hamburg | May |

The bars need not line up. A table too wide for the screen can be pushed
sideways.

## Footnotes

A footnote has two parts: the marker in the text and the note below it. The
number between them is yours to choose, it only has to match.

```markdown
Revenue doubled[^1].

[^1]: Measured against the same quarter last year.
```

Revenue doubled[^1].

[^1]: Measured against the same quarter last year.

The notes collect at the end of the text. Clicking a marker jumps down to its
note; your browser's back button, or your phone's back gesture, brings you
straight back to where you were reading.

## Pictures

Pictures live in posts only, and only ones you uploaded yourself. The way in is
**Add images** in the editor, or simply dragging an image file into the text. A
picture sitting in the middle of the text can then be pushed left, right or
into the centre with the small buttons above the editor, and the text wraps
around it.

Pointing at somebody else's picture on the web is deliberately not possible.
Every view of your post would otherwise report every reader's IP address to a
server that is not ours.

## What we do not render

HTML is shown, not executed. Write `<b>bold</b>` and `<b>bold</b>` is what your
readers see. That is a security decision: if we ran other people's HTML, it
could be used to smuggle hostile code onto another member's page.

Also absent are checkbox task lists and embedded videos or maps. A link to the
video does the job.

## When something does not work

Write a post mentioning `@vutuv`, or file it as a
[bug on GitHub](https://github.com/wintermeyer/vutuv/issues). vutuv is open
source, and the rules on this page are code in the repository.
