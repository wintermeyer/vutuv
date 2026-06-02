defmodule Mix.Tasks.Avatar.Optimize do
  @moduledoc """
  Re-compress the large JPEG variant of every user's avatar in place.

  Operates on `<:uploads_dir_prefix>/avatars/<user_id>` (the same root the web
  app reads/writes; see `config/runtime.exs`). Requires the ImageMagick
  `convert` and `guetzli` binaries on the host's `$PATH`.
  """

  use Mix.Task
  import Ecto.Query
  alias Vutuv.Accounts.User
  alias Vutuv.Repo

  @shortdoc "Optimize the file size of JPEG avatars."

  def run(_args) do
    Mix.Task.run("app.start", [])
    users = Repo.all(from(u in User, where: not is_nil(u.avatar)))

    for user <- users do
      if trunc(user.id / 100) == user.id / 100 do
        IO.puts("* #{user.id}")
      end

      optimize_user_avatar(user)
    end
  end

  defp avatars_dir(id) do
    Path.join([
      Application.get_env(:vutuv, :uploads_dir_prefix, ""),
      "avatars",
      Integer.to_string(id)
    ])
  end

  defp optimize_user_avatar(user) do
    source_path = avatars_dir(user.id)
    size_name = "large"
    width = 512
    height = 512

    for file_extension <- ["jpeg", "jpg"] do
      original_file = List.first(Path.wildcard("#{source_path}/*_original.#{file_extension}"))
      target_file = List.first(Path.wildcard("#{source_path}/*_#{size_name}.#{file_extension}"))

      if original_file do
        optimize_avatar_file(
          source_path,
          original_file,
          target_file,
          file_extension,
          size_name,
          width,
          height
        )
      end
    end
  end

  defp optimize_avatar_file(
         source_path,
         original_file,
         target_file,
         file_extension,
         size_name,
         width,
         height
       ) do
    temp_dir = "#{source_path}/tmp"
    source_file = "#{temp_dir}/original.#{file_extension}"

    tmp_file =
      "#{temp_dir}/#{size_name}-#{Integer.to_string(width)}x#{Integer.to_string(height)}.#{file_extension}"

    q75_file =
      List.first(String.split(tmp_file, ".#{file_extension}")) <>
        "-q75.#{file_extension}"

    optimized_file =
      List.first(String.split(tmp_file, ".#{file_extension}")) <>
        "-optimized.#{file_extension}"

    File.mkdir(temp_dir)
    File.cp(original_file, source_file)

    System.cmd("convert", [
      source_file,
      "-colorspace",
      "YUV",
      "-resize",
      "#{Integer.to_string(width)}x#{Integer.to_string(height)}",
      "-strip",
      tmp_file
    ])

    run_guetzli_optimization(
      source_path,
      tmp_file,
      q75_file,
      optimized_file,
      target_file,
      width,
      height
    )

    File.rm_rf(temp_dir)
  end

  defp run_guetzli_optimization(
         source_path,
         tmp_file,
         q75_file,
         optimized_file,
         target_file,
         width,
         height
       ) do
    with {:ok, tmp_file_stat} <- File.stat(tmp_file),
         true <- tmp_file_stat.size > 0 do
      System.cmd("guetzli", ["-quality", "75", tmp_file, q75_file])

      blend_and_replace(
        source_path,
        tmp_file,
        q75_file,
        optimized_file,
        target_file,
        width,
        height
      )
    end
  end

  defp blend_and_replace(
         source_path,
         tmp_file,
         q75_file,
         optimized_file,
         target_file,
         width,
         height
       ) do
    with {:ok, q75_file_stat} <- File.stat(q75_file),
         true <- q75_file_stat.size > 0 do
      System.cmd("convert", [
        tmp_file,
        q75_file,
        "-fx",
        "hypot(#{Integer.to_string(trunc(width / 2))}-i, #{Integer.to_string(trunc(height / 2))}-j) < #{Integer.to_string(trunc(width / 2))} ? u : v",
        optimized_file
      ])

      maybe_replace_target(source_path, optimized_file, target_file)
    end
  end

  defp maybe_replace_target(source_path, optimized_file, target_file) do
    with true <- target_file != nil,
         {:ok, old_file_stat} <- File.stat(target_file),
         {:ok, new_file_stat} <- File.stat(optimized_file),
         true <- new_file_stat.size > 0,
         true <- new_file_stat.size < old_file_stat.size do
      File.rename(optimized_file, target_file)

      IO.puts(source_path)
      IO.puts(Float.round((old_file_stat.size - new_file_stat.size) / 1024, 1))
      IO.puts("#{100 - Float.round(new_file_stat.size / old_file_stat.size * 100)} %")
      IO.puts("")
    end
  end
end
