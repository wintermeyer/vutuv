defmodule Vutuv.Posts.PostVideoFrame do
  @moduledoc """
  One still pulled from a post's clip (issues #1908, #1909): the pipeline
  takes the opening frame, one every twenty seconds and one at every hard cut
  (at most `Vutuv.Videos.max_frames/0`), and each goes through the AI image
  check as its own scan subject — the scan queue keys one open scan per
  subject, so a frame has to be a row of its own.

  The same rows are the strip the author picks the cover from: `position`
  orders them, `seconds` says where in the clip each sits, and the JPEG lives
  beside the original in the private tree
  (`Vutuv.PostVideoStore.frame_path/2`), so a frame the check has not cleared
  is never on a served path.
  """

  use VutuvWeb, :model

  schema "post_video_frames" do
    belongs_to(:video, Vutuv.Posts.PostVideo)

    field(:position, :integer)
    field(:seconds, :integer)
    field(:scene_cut, :boolean, default: false)
    field(:moderation, :string, default: "pending")

    timestamps()
  end
end
