defmodule VutuvWeb.UserTagHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/user_tag/*")

  @doc """
  A sortable column header for the endorsers table. Renders a link that sets
  `?sort=<field>&dir=<next>` (dropping `page`, so sorting returns to page 1).
  Clicking the active column flips the direction; clicking another column
  starts at its natural default (newest-first for `date`, A→Z otherwise). The
  active column shows a ▲/▼ arrow for the current direction.
  """
  attr(:field, :string, required: true, doc: ~s(the sort key: "name" | "username" | "date"))
  attr(:label, :string, required: true)
  attr(:sort, :string, required: true, doc: "the currently active sort key")
  attr(:dir, :string, required: true, doc: ~s(the current direction: "asc" | "desc"))

  def sort_link(assigns) do
    active? = assigns.sort == assigns.field

    next_dir =
      cond do
        active? and assigns.dir == "asc" -> "desc"
        active? -> "asc"
        assigns.field == "date" -> "desc"
        true -> "asc"
      end

    assigns = assign(assigns, active?: active?, next_dir: next_dir)

    ~H"""
    <a href={"?sort=#{@field}&dir=#{@next_dir}"} class="inline-flex items-center gap-1">
      {@label}<span :if={@active?} aria-hidden="true">{if @dir == "asc", do: "▲", else: "▼"}</span>
    </a>
    """
  end
end
