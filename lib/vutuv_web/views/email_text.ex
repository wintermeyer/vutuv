defmodule VutuvWeb.EmailText do
  @moduledoc false
  require EEx
  import VutuvWeb.UserHelpers

  @template_dir "lib/vutuv_web/templates/email"

  # Compile all .text.eex templates into named functions at compile time.
  # Each template "foo.text.eex" becomes a function foo(assigns).
  # Templates starting with "_" are partials and are called via render/1.
  #
  # The wildcard is read once, at compile time. `function_from_file/5` registers
  # each matched template as an `@external_resource`, so *editing* a template
  # recompiles this module. *Adding* a brand-new template does not (the new file
  # is not yet a tracked resource), so after creating one, recompile this module
  # (a clean/CI build does this for you). See the email/ templates directory.
  for path <- Path.wildcard(Path.join(@template_dir, "*.text.eex")) do
    basename = Path.basename(path, ".text.eex")
    func_name = String.to_atom(basename)

    EEx.function_from_file(:def, func_name, path, [:assigns])
  end

  @doc """
  Renders a text email template by name, e.g. render("login_email_en.text", assigns).
  """
  def render(template, assigns \\ %{}) do
    func =
      template
      |> String.trim_trailing(".text")
      |> String.to_existing_atom()

    apply(__MODULE__, func, [assigns])
  end
end
