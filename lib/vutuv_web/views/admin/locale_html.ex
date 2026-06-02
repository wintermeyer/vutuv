defmodule VutuvWeb.Admin.LocaleHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../../templates/admin/locale/*")
end
