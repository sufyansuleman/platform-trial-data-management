# ---------------------------------------------------------------------------
# Render every monitoring report and assemble the published site.
#
#   Rscript scripts/render_reports.R           # every site
#   Rscript scripts/render_reports.R DK-01     # one site, for a quick look
#
# Output goes to _site/, which is what CI publishes to GitHub Pages. The point
# of publishing is that anybody reading the repository can click a link and see
# the actual report rather than take a screenshot's word for it.
# ---------------------------------------------------------------------------

suppressMessages({
  library(dplyr)
  library(targets)
  library(parallel)
})

for (file in list.files("R", pattern = "[.]R$", recursive = TRUE,
                        full.names = TRUE)) {
  source(file)
}

cfg <- load_trial_config()
sites <- resolve_sites(cfg)

requested <- commandArgs(trailingOnly = TRUE)
site_ids <- if (length(requested)) requested else sites$site_id
stopifnot(all(site_ids %in% sites$site_id))

output_dir <- "_site"
dir.create(output_dir, showWarnings = FALSE)

started <- Sys.time()

# -- Central report ---------------------------------------------------------
message("Rendering central monitoring report")
quarto::quarto_render("reports/central_monitoring.qmd",
                      output_file = "central_monitoring.html", quiet = TRUE)
file.rename(file.path("reports", "central_monitoring.html"),
            file.path(output_dir, "central_monitoring.html"))

# -- One report per site ----------------------------------------------------
# Rendered in parallel. Each render spawns its own R session, and that startup
# -- loading the packages and sourcing R/ -- is most of the cost, so the work
# parallelises almost linearly. Serially, 25 reports took seven minutes, which
# breaks the five-minute budget in the definition of done.
#
# Reports stay self-contained (`embed-resources`). That costs about three
# seconds each but means every report is a single file that can be sent to a
# site coordinator, and it avoids parallel renders colliding over a shared
# supporting-files directory.
render_one_site <- function(site_id) {
  # Each worker renders its own COPY of the document. Quarto names its
  # intermediate files after the input, so several processes rendering the
  # same .qmd at once overwrite each other's working files and fail.
  worker_input <- file.path("reports", paste0("site_monitoring_", site_id, ".qmd"))
  file.copy("reports/site_monitoring.qmd", worker_input, overwrite = TRUE)
  on.exit(unlink(worker_input), add = TRUE)

  output_file <- paste0("site_", site_id, ".html")
  quarto::quarto_render(
    worker_input,
    execute_params = list(site_id = site_id),
    output_file = output_file,
    quiet = TRUE
  )
  output_file
}

workers <- max(1, min(4, parallel::detectCores() - 1, length(site_ids)))
message(sprintf("Rendering %d site reports across %d worker(s)",
                length(site_ids), workers))

if (workers == 1) {
  rendered <- lapply(site_ids, render_one_site)
} else {
  cluster <- parallel::makePSOCKcluster(workers)
  on.exit(parallel::stopCluster(cluster), add = TRUE)

  # Worker sessions do not run the project .Rprofile, so the renv library has
  # to be handed to them explicitly or they will not find quarto or dplyr.
  parallel::clusterCall(cluster, function(paths, wd) {
    .libPaths(paths)
    setwd(wd)
  }, .libPaths(), getwd())

  rendered <- parallel::parLapply(cluster, site_ids, render_one_site)
}

for (output_file in unlist(rendered)) {
  file.rename(file.path("reports", output_file),
              file.path(output_dir, output_file))
}

# -- Index page -------------------------------------------------------------
# Written by hand rather than rendered: it is a directory, and a Quarto
# document for it would be more machinery than the job needs.
findings <- tar_read(findings)
endpoint <- tar_read(dawols)

site_rows <- sites |>
  left_join(
    findings |> filter(severity == "critical") |> count(site_id, name = "critical"),
    by = "site_id"
  ) |>
  left_join(
    endpoint |> group_by(site_id) |>
      summarise(records = n(), .groups = "drop"),
    by = "site_id"
  ) |>
  mutate(critical = coalesce(critical, 0L),
         records = coalesce(records, 0L)) |>
  arrange(site_id)

rows_html <- paste0(
  "<tr><td><a href='site_", site_rows$site_id, ".html'>",
  site_rows$site_id, "</a></td><td>", site_rows$site_name,
  "</td><td>", site_rows$country,
  "</td><td>", format(site_rows$initiation_date, "%b %Y"),
  "</td><td class='n'>", site_rows$records,
  "</td><td class='n'>", site_rows$critical, "</td></tr>",
  collapse = "\n"
)

index <- sprintf('<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Platform trial data monitoring</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
         max-width: 60rem; margin: 3rem auto; padding: 0 1.5rem; line-height: 1.55; }
  h1 { margin-bottom: 0.25rem; }
  .sub { color: #666; margin-top: 0; }
  .warn { background: #fff8e1; border-left: 4px solid #f0ad4e; padding: 0.75rem 1rem;
          margin: 1.5rem 0; }
  table { border-collapse: collapse; width: 100%%; margin-top: 1rem; }
  th, td { text-align: left; padding: 0.45rem 0.6rem; border-bottom: 1px solid #ddd; }
  th { border-bottom: 2px solid #999; }
  td.n { text-align: right; font-variant-numeric: tabular-nums; }
  a { color: #0b5fa5; }
  @media (prefers-color-scheme: dark) {
    body { background: #14161a; color: #e6e6e6; }
    th, td { border-color: #333; }
    .warn { background: #2a2416; border-color: #8a6d1f; }
    a { color: #6fb3f2; }
  }
</style>
</head>
<body>
<h1>Platform trial data monitoring</h1>
<p class="sub">Synthetic Adaptive Platform Trial in Critical Illness &mdash;
generated %s from rule set %s</p>

<div class="warn">
<strong>All data here is synthetic</strong>, generated from a fixed seed by the code in
this repository. Site names are invented. This is an independent educational project
with no affiliation to any real trial, hospital or research group.
</div>

<p><a href="central_monitoring.html"><strong>Central monitoring report</strong></a>
&mdash; the coordinating centre view: which sites need attention, how well the
validation rules actually perform against known defects, and what the ingest
layer had to undo.</p>

<h2>Site reports</h2>
<p>One per site. Each opens with the actions for that site this week; the charts
are the evidence behind them.</p>

<table>
<thead><tr><th>Site</th><th>Name</th><th>Country</th><th>Initiated</th>
<th class="n">Endpoint records</th><th class="n">Critical findings</th></tr></thead>
<tbody>
%s
</tbody>
</table>
</body>
</html>
', format(Sys.Date(), "%d %B %Y"), rule_set_version(), rows_html)

writeLines(index, file.path(output_dir, "index.html"))

elapsed <- round(as.numeric(difftime(Sys.time(), started, units = "mins")), 1)
message(sprintf("\nRendered %d site reports plus the central report in %s minutes.",
                length(site_ids), elapsed))
message("Output in ", normalizePath(output_dir))
