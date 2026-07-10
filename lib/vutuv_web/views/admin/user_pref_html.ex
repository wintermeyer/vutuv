defmodule VutuvWeb.Admin.UserPrefHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.Admin.PrefHTML, only: [pref_control: 1, pref_error: 1]
  import VutuvWeb.UserHelpers, only: [full_name: 1]

  embed_templates("../../templates/admin/user_pref/*")
end
