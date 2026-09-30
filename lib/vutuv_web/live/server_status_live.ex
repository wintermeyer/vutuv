defmodule VutuvWeb.ServerStatusLive do
  @moduledoc """
  `/system/status`: how the servers behind this installation are doing, one
  card per machine, open to everybody and linked from every page's footer.

  Each card shows the processor (with a cell per core), memory, the disks added
  up, the uptime and every graphics card with its load, memory, temperature and
  power. The numbers come from `Vutuv.ServerStatus.snapshot/0`, which the
  sampler rewrites every few seconds; this page re-reads it on the same beat,
  so it never reads a server itself and a crowd of viewers costs nothing extra.

  Servers are "Server 1", "Server 2" …, never their host, and disks are one
  total per server rather than a list of mount points: the page is public, and
  both would tell an attacker where to look.
  """
  use VutuvWeb, :live_view

  alias Vutuv.ServerStatus

  # The first reading needs a second one before it has a percentage (see the
  # sampler), so a page opened on a fresh server asks again soon.
  @first_refresh 1_500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @first_refresh)

    {:ok,
     socket
     |> assign(:page_title, gettext("Server status"))
     |> assign(:interval_seconds, div(ServerStatus.interval(), 1_000))
     |> load()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, ServerStatus.interval())
    {:noreply, load(socket)}
  end

  defp load(socket) do
    assign(socket, servers: ServerStatus.snapshot(), now: System.os_time(:second))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6">
      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("Server status")}</h1>
      <p class="mt-2 mb-6 max-w-prose text-sm text-slate-600 dark:text-slate-400">
        {ngettext(
          "How the servers behind this site are doing right now. The page updates itself every second.",
          "How the servers behind this site are doing right now. The page updates itself every %{count} seconds.",
          @interval_seconds
        )}
      </p>

      <.card :if={@servers == []}>
        <p class="text-sm text-slate-600 dark:text-slate-400">
          {gettext("The first readings arrive in a few seconds.")}
        </p>
      </.card>

      <div class="grid items-start gap-4 md:grid-cols-2 xl:grid-cols-3">
        <.server :for={server <- @servers} server={server} now={@now} />
      </div>
    </div>
    """
  end

  attr(:server, :map, required: true)
  attr(:now, :integer, required: true)

  defp server(%{server: %{reachable?: false}} = assigns) do
    ~H"""
    <.card id={"server-#{@server.number}"} class="flex flex-col gap-3">
      <div class="flex items-start justify-between gap-2" data-state="unreachable">
        <h2 class="text-base font-semibold">{server_name(@server)}</h2>
        <.status_pill tone={tone(:unreachable)}>{state_label(:unreachable)}</.status_pill>
      </div>
      <p class="text-sm text-slate-600 dark:text-slate-400">
        {gettext("This server did not answer the last reading.")}
      </p>
    </.card>
    """
  end

  defp server(assigns) do
    assigns = Map.put(assigns, :state, state(assigns.server))

    ~H"""
    <.card id={"server-#{@server.number}"} class="flex flex-col gap-5">
      <div class="flex items-start justify-between gap-2" data-state="ok">
        <h2 class="text-base font-semibold">{server_name(@server)}</h2>
        <.status_pill tone={tone(@state)}>{state_label(@state)}</.status_pill>
      </div>

      <%!-- A plain grid rather than a <dl>: the legacy stylesheet gives every
            dl/dt/dd its own weights, margins and borders. --%>
      <div class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
        <span class="text-slate-500 dark:text-slate-400">{gettext("Processor")}</span>
        <span class="min-w-0 break-words">{cpu_line(@server)}</span>
        <span :if={@server.os} class="text-slate-500 dark:text-slate-400">{gettext("System")}</span>
        <span :if={@server.os} class="min-w-0 break-words">{@server.os}</span>
        <span :if={@server.booted_at} class="text-slate-500 dark:text-slate-400">{gettext("Running for")}</span>
        <span :if={@server.booted_at} class="tabular-nums">
          {duration(max(@now - @server.booted_at, 0) * 1_000)}
        </span>
      </div>

      <div class="flex flex-col gap-2">
        <.meter label={gettext("CPU")} value={@server.cpu} text={percent(@server.cpu)} />
        <p :if={@server.load} class="text-xs tabular-nums text-slate-500 dark:text-slate-400">
          {gettext("Load %{one} · %{five} · %{fifteen}", load_values(@server.load))}
        </p>
        <div
          :if={@server.per_core != []}
          class="grid grid-cols-[repeat(auto-fill,minmax(0.75rem,1fr))] gap-0.5"
          aria-hidden="true"
        >
          <span
            :for={core <- @server.per_core}
            class="h-3 rounded-sm bg-brand-500 dark:bg-brand-400"
            style={"opacity: #{core_opacity(core)}"}
          ></span>
        </div>
        <.sparkline :if={length(@server.cpu_history) > 1} values={@server.cpu_history} />
      </div>

      <.meter
        :if={@server.mem_total}
        label={gettext("Memory")}
        value={share(@server.mem_used, @server.mem_total)}
        text={size_pair(@server.mem_used, @server.mem_total)}
      />

      <.meter
        :if={@server.disk}
        label={gettext("Disks")}
        value={share(@server.disk.used, @server.disk.total)}
        text={size_pair(@server.disk.used, @server.disk.total)}
      />

      <div
        :for={gpu <- @server.gpus}
        class="flex flex-col gap-2 border-t border-dashed border-slate-200 pt-4 dark:border-slate-700"
      >
        <.section_title>{gettext("Graphics card")}</.section_title>
        <p class="text-sm font-semibold">{gpu.name}</p>
        <.meter label={gettext("GPU load")} value={gpu.utilization} text={percent(gpu.utilization)} />
        <.meter
          :if={gpu.mem_total}
          label={gettext("Graphics memory")}
          value={share(gpu.mem_used, gpu.mem_total)}
          text={size_pair(gpu.mem_used, gpu.mem_total)}
        />
        <p class="text-xs tabular-nums text-slate-500 dark:text-slate-400">{gpu_line(gpu)}</p>
        <.sparkline :if={length(gpu.history) > 1} values={gpu.history} />
      </div>
    </.card>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:text, :string, required: true)

  defp meter(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <div class="flex justify-between gap-2 text-sm">
        <span>{@label}</span>
        <b class="font-semibold tabular-nums">{@text}</b>
      </div>
      <div
        class="h-2 overflow-hidden rounded bg-slate-100 dark:bg-slate-800"
        role="meter"
        aria-label={@label}
        aria-valuemin="0"
        aria-valuemax="100"
        aria-valuenow={@value && round(@value)}
      >
        <div class={["h-full rounded", bar_class(level(@value))]} style={"width: #{bar_width(@value)}%"}></div>
      </div>
    </div>
    """
  end

  attr(:values, :list, required: true)

  # A line over the readings the sampler still holds (the last quarter hour at
  # the default interval), always on a 0-100 % scale so a quiet server looks
  # quiet rather than being stretched into drama.
  defp sparkline(assigns) do
    assigns = Map.put(assigns, :points, spark_points(assigns.values))

    ~H"""
    <svg viewBox="0 0 300 44" preserveAspectRatio="none" class="block h-11 w-full" aria-hidden="true">
      <polygon points={"0,44 #{@points} 300,44"} class="fill-brand-500/10 dark:fill-brand-400/15" />
      <polyline
        points={@points}
        fill="none"
        class="stroke-brand-500 dark:stroke-brand-400"
        stroke-width="2"
        vector-effect="non-scaling-stroke"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  defp spark_points(values) do
    last = max(length(values) - 1, 1)

    values
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {value, i} ->
      "#{Float.round(i * 300 / last, 1)},#{Float.round(42 - value / 100 * 38, 1)}"
    end)
  end

  defp server_name(server), do: gettext("Server %{number}", number: server.number)

  defp cpu_line(%{cpu_model: nil, cores: cores}),
    do: ngettext("1 core", "%{count} cores", cores)

  defp cpu_line(%{cpu_model: model, cores: cores}),
    do: ngettext("%{model}, 1 core", "%{model}, %{count} cores", cores, model: model)

  defp gpu_line(gpu) do
    [
      gpu.temperature && gettext("%{degrees} °C", degrees: round(gpu.temperature)),
      power(gpu)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp power(%{power: power, power_limit: limit}) when is_number(power) and is_number(limit),
    do: gettext("%{watts} / %{limit} W", watts: round(power), limit: round(limit))

  defp power(%{power: power}) when is_number(power),
    do: gettext("%{watts} W", watts: round(power))

  defp power(_gpu), do: nil

  defp load_values({one, five, fifteen}),
    do: [one: decimal(one, 2), five: decimal(five, 2), fifteen: decimal(fifteen, 2)]

  # The worst of processor, memory and disks decides the card's pill.
  defp state(server) do
    [
      server.cpu,
      share(server.mem_used, server.mem_total),
      server.disk && share(server.disk.used, server.disk.total)
    ]
    |> Enum.filter(&is_number/1)
    |> Enum.max(fn -> nil end)
    |> level()
  end

  defp level(value) when is_number(value) and value >= 90, do: :critical
  defp level(value) when is_number(value) and value >= 75, do: :high
  defp level(_value), do: :normal

  defp state_label(:normal), do: gettext("Up and running")
  defp state_label(:high), do: gettext("Busy")
  defp state_label(:critical), do: gettext("Critical")
  defp state_label(:unreachable), do: gettext("Not answering")

  defp tone(:normal),
    do: "bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"

  defp tone(:high), do: "bg-amber-50 text-amber-800 dark:bg-amber-950 dark:text-amber-300"
  defp tone(:critical), do: "bg-red-50 text-red-700 dark:bg-red-950 dark:text-red-300"
  defp tone(:unreachable), do: "bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-300"

  defp bar_class(:critical), do: "bg-red-600 dark:bg-red-500"
  defp bar_class(:high), do: "bg-amber-500"
  defp bar_class(:normal), do: "bg-slate-500 dark:bg-slate-400"

  defp bar_width(value) when is_number(value),
    do: (value * 1.0) |> max(0.0) |> min(100.0) |> Float.round(1)

  defp bar_width(_value), do: 0

  defp core_opacity(nil), do: "0.15"
  defp core_opacity(value), do: Float.to_string(Float.round(0.15 + value / 118, 2))

  defp share(used, total) when is_number(used) and is_number(total) and total > 0,
    do: used / total * 100

  defp share(_used, _total), do: nil

  defp percent(nil), do: "–"
  defp percent(value), do: gettext("%{percent}%", percent: round(value))

  # Memory and disks as "80,9 / 128 GB" or "2,31 / 3,84 TB": one unit per
  # pair, picked by the total, in decimal units as the drive makers count.
  defp size_pair(used, total)
       when is_integer(used) and is_integer(total) and total >= 1_000_000_000_000,
       do:
         gettext("%{used} / %{total} TB",
           used: decimal(used / 1.0e12, 2),
           total: decimal(total / 1.0e12, 2)
         )

  defp size_pair(used, total) when is_integer(used) and is_integer(total),
    do: gettext("%{used} / %{total} GB", used: gigabytes(used), total: gigabytes(total))

  defp size_pair(_used, _total), do: "–"

  defp gigabytes(bytes) when bytes >= 100_000_000_000, do: delimited_count(round(bytes / 1.0e9))
  defp gigabytes(bytes), do: decimal(bytes / 1.0e9, 1)
end
