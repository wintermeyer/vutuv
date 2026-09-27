# Dev server for the PDF trailer recording.
#
#   PORT=4078 mix run --no-start scripts/pdf_trailer/server.exs
#
# The dev database is a copy of production with real fediverse followers and
# push subscriptions, so nothing this server does may reach another machine:
# fediverse delivery, web push and screenshot capture are off. The AI image
# check is off too, so the file's preview pages pass at once and the waiting
# post publishes while the camera runs.
Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
Application.put_env(:vutuv, :fediverse_enabled, false, persistent: true)
Application.put_env(:vutuv, :web_push_enabled, false, persistent: true)
Application.put_env(:vutuv, :generate_screenshots, false, persistent: true)
Application.put_env(:vutuv, :moderate_images, false, persistent: true)

{:ok, _} = Application.ensure_all_started(:vutuv)

IO.puts("TRAILER_SERVER_UP")
Process.sleep(:infinity)
