defmodule Vutuv.Uploads.OriginalsTest do
  @moduledoc """
  Locks the shared private-originals toolset every uploader goes through:
  originals live under `<uploads_dir_prefix>/originals/<storage_dir>/` with
  the fixed name `original<ext>`, are never served, and there is exactly one
  per storage dir (a re-upload clears the stale one, whatever its extension).
  """
  # Not async: these tests set the global `:uploads_dir_prefix` application env.
  use ExUnit.Case, async: false

  alias Vutuv.Uploads.Originals

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_originals_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      if prev,
        do: Application.put_env(:vutuv, :uploads_dir_prefix, prev),
        else: Application.delete_env(:vutuv, :uploads_dir_prefix)
    end)

    {:ok, tmp: tmp}
  end

  defp source!(tmp, name) do
    path = Path.join(tmp, name)
    File.write!(path, "image bytes of #{name}")
    path
  end

  test "store/3 places the original at originals/<storage_dir>/original<ext>", %{tmp: tmp} do
    src = source!(tmp, "upload.jpg")

    assert :ok = Originals.store("avatars/7", src, ".jpg")
    assert File.read!(Path.join(tmp, "originals/avatars/7/original.jpg")) =~ "upload.jpg"
  end

  test "store/3 clears a stale original with a different extension", %{tmp: tmp} do
    assert :ok = Originals.store("avatars/7", source!(tmp, "old.jpg"), ".jpg")
    assert :ok = Originals.store("avatars/7", source!(tmp, "new.png"), ".png")

    assert File.ls!(Path.join(tmp, "originals/avatars/7")) == ["original.png"]
  end

  test "path/1 finds the original whatever its extension, nil when absent", %{tmp: tmp} do
    assert Originals.path("avatars/7") == nil

    assert :ok = Originals.store("avatars/7", source!(tmp, "up.PNG"), ".PNG")
    assert Originals.path("avatars/7") == Path.join(tmp, "originals/avatars/7/original.PNG")
  end

  test "delete/1 removes the original dir and tolerates absence", %{tmp: tmp} do
    assert :ok = Originals.store("post_images/abc", source!(tmp, "up.jpg"), ".jpg")

    assert :ok = Originals.delete("post_images/abc")
    refute File.exists?(Path.join(tmp, "originals/post_images/abc"))
    assert :ok = Originals.delete("post_images/abc")
  end
end
