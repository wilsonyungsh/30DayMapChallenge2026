pacman::p_load(tidyverse, readabs, sf, janitor, strayr, spdep, mapgl)

t <- read_api_dataflows()
t2 <- read_api_datastructure(id = "C21_G56_SA2")
# G56 is counted by place of usual residence: employed persons living in each SA2, not jobs located there
t3 <- read_api(id = "C21_G56_SA2", datakey = list(
  indp = LETTERS[1:19], region_type = "SA2",
  occp = "_T"))

## GCCSA for Eastern Seaboard
gcc_sa2 <- strayr::read_absmap("sa22021", remove_year_suffix = TRUE) |>
  select(contains(c("sa2", "gcc", "areasqkm"))) |>
  filter(gcc_code %in% c("1GSYD", "2GMEL", "3GBRI"))

## 3 gcc only employed persons by sa2 (place of usual residence)
indp_pop <-
  t3 |> select(indp, region, obs_value) |>
  inner_join(gcc_sa2 |> st_drop_geometry(), by = c("region" = "sa2_code")) |>
  mutate(indp = labelled::to_character(indp))

# calculate location quoient
indp_summary_gcc <-
  indp_pop |> group_by(gcc_name, gcc_code, indp) |> reframe(total = sum(obs_value))

## Resident workers by indp and GCC
indp_gcc_wide <-
  indp_summary_gcc |> select(-gcc_code) |>
  pivot_wider(names_from = gcc_name, values_from = total) |>
  janitor::adorn_totals("row")

indp_gcc_wide_pr <-
  indp_summary_gcc |> select(-gcc_code) |> group_by(gcc_name) |>
  mutate(pr = 100 * round(total / sum(total), 4)) |> select(-total) |>
  pivot_wider(names_from = gcc_name, values_from = pr)

## calculating Location Quotient for 3 GCC SA2s
lq <-
  indp_pop |> group_by(gcc_name, gcc_code) |> mutate(ttl_workers = sum(obs_value)) |>
  group_by(gcc_code, gcc_name, indp) |> mutate(ttl_workers_indp = sum(obs_value)) |>
  group_by(sa2_name, region) |> mutate(sa2_workers = sum(obs_value)) |>
  group_by(sa2_name, region, indp) |> mutate(sa2_workers_indp = sum(obs_value)) |>
  mutate(lq = (sa2_workers_indp / sa2_workers) / (ttl_workers_indp / ttl_workers),
    worker_density_sqkm = round(obs_value / (areasqkm), 4))

## Master data contains SA2 LQ by industry and 3 GCCSA
master <-
  gcc_sa2 |> select(sa2_code) |>
  inner_join(lq |> filter(sa2_workers > 50), # minimum SA2 resident workers threshold
    by = c("sa2_code" = "region")) %>%
  split(.$gcc_code)

# Top 5 for each gcc
top5_ind_gcc <-
  unique(indp_summary_gcc$gcc_code) |>
  map(~ indp_summary_gcc |> filter(gcc_code == .x) |>
    slice_max(n = 5, order_by = total) |> pull(indp) |> as.character()) |>
  setNames(unique(indp_summary_gcc$gcc_code))

## spatial clustering — LISA on LQ for one GCC x industry
run_lisa <- function(df, k = 8, nsim = 999) {
  df <- st_transform(df, 3577)
  nb <- knn2nb(knearneigh(st_centroid(st_geometry(df)), k = k))
  lw <- nb2listw(nb, style = "W")

  gm <- moran.mc(df$lq, lw, nsim = nsim)
  lisa <- localmoran_perm(df$lq, lw, nsim = nsim)

  df |>
    mutate(moran_i = gm$statistic, moran_p = gm$p.value,
      Ii = lisa[, "Ii"],
      p_sim = lisa[, "Pr(z != E(Ii)) Sim"],
      quad = as.character(attr(lisa, "quadr")$mean),
      cluster = if_else(p_sim < 0.05, quad, "Not significant"),
      gi_z = as.numeric(localG(lq, nb2listw(include.self(nb), style = "W"))))
}

## Top 5 industries across 3 GCCs (union); LISA run within each GCC
top_inds <- top5_ind_gcc |> unlist() |> unique()

set.seed(2026)
gcc_lisa <-
  top_inds |>
  map(\(ind) names(master) |>
    map(\(g) master[[g]] |> filter(indp == ind) |> run_lisa()) |>
    bind_rows()) |>
  setNames(top_inds)

# global Moran's I and cluster counts by GCC x industry
lisa_summary <-
  gcc_lisa |> bind_rows() |> st_drop_geometry() |>
  group_by(gcc_name, indp) |>
  summarise(moran_i = first(moran_i), moran_p = first(moran_p),
    hh = sum(cluster == "High-High"), ll = sum(cluster == "Low-Low"),
    hh_worker_share = sum(sa2_workers_indp[cluster == "High-High"]) / sum(sa2_workers_indp),
    .groups = "drop")

lisa_summary |> select(gcc_name, indp, moran_i) |>
  pivot_wider(names_from = gcc_name, values_from = moran_i)

## Vis — LISA cluster map, switchable by industry, 3 GCCs
lisa_value <- c("High-High", "Low-Low", "High-Low", "Low-High", "Not significant")
lisa_color <- c("#d7191c", "#2c7bb6", "#fdae61", "#abd9e9", "#eeeeee")
legend_bg <- legend_style(background_color = "white", background_opacity = 1)

gcc_lisa_map <- gcc_lisa |>
  map(~ .x |> st_transform(4326) |>
    mutate(tp = paste0("<b>", sa2_name, "</b> (", gcc_name, ")<br>",
      indp, " resident workers: ", sa2_workers_indp, "<br>",
      "LQ: ", round(lq, 2), "<br>",
      "Cluster: ", cluster, " (p = ", p_sim, ")")))

# city buttons: fit map to each GCC
gcc_bbox <- gcc_lisa_map[[1]] |> group_by(gcc_name) |> summarise() |>
  mutate(bbox = map_chr(geometry, ~ jsonlite::toJSON(matrix(st_bbox(.x), 2, byrow = TRUE))))
city_btn_html <- paste0(
  '<div style="background:white; padding:6px; border-radius:4px; font-family:sans-serif;">',
  paste0('<button class="city-btn" style="display:inline-block; width:auto; height:auto;',
    ' margin:2px; padding:4px 10px; cursor:pointer;" data-bounds="',
    gcc_bbox$bbox, '">', str_remove(gcc_bbox$gcc_name, "Greater "), "</button>", collapse = ""),
  "</div>")

# summary table: top 5 industries, employed residents and % of GCC total
top5_long <-
  indp_summary_gcc |> group_by(gcc_name) |>
  mutate(pr = total / sum(total)) |> ungroup() |>
  filter(indp %in% top_inds) |>
  mutate(city = str_remove(gcc_name, "Greater "),
    rank_total = ave(total, indp, FUN = sum)) |>
  arrange(desc(rank_total), city) |>
  select(indp, city, total, pr)

top5_tbl <-
  top5_long |>
  bind_rows(top5_long |> group_by(city) |>
    summarise(indp = "Total (top 5)", total = sum(total), pr = sum(pr))) |>
  mutate(val = paste0(format(total, big.mark = ",", trim = TRUE), " (", sprintf("%.1f", 100 * pr), "%)")) |>
  select(indp, city, val) |>
  pivot_wider(names_from = city, values_from = val)

td_style <- ' style="padding:2px 8px; text-align:right; white-space:nowrap;"'
top5_tbl_html <- paste0(
  '<details close style="background:white; padding:6px 10px; border-radius:4px;',
  ' font-family:sans-serif; font-size:12px; box-shadow:0 1px 4px rgba(0,0,0,.3);">',
  '<summary class="drag-handle" style="font-weight:bold; cursor:move;">',
  "Top 5 industries — employed residents (% of city)</summary>",
  '<table style="border-collapse:collapse; margin-top:4px;">',
  '<tr><th style="text-align:left; padding:2px 8px;">Industry</th>',
  paste0("<th", td_style, ">", names(top5_tbl)[-1], "</th>", collapse = ""), "</tr>",
  pmap_chr(top5_tbl, \(indp, ...) paste0(
    if (indp == "Total (top 5)") '<tr style="font-weight:bold; border-top:1px solid #999;">' else "<tr>",
    '<td style="padding:2px 8px;">', indp, "</td>",
    paste0("<td", td_style, ">", c(...), "</td>", collapse = ""), "</tr>")) |>
    paste(collapse = ""),
  "</table>",
  '<div style="margin-top:4px; color:#666; font-size:11px;">',
  "Source: ABS Census of Population and Housing 2021, G56 (place of usual residence)</div>",
  "</details>")

data_source <- "Data: ABS Census of Population and Housing 2021, G56 Industry of employment (place of usual residence)"

# official GCC boundaries (dissolving SA2s leaves slivers along shared edges)
gcc_boundary <- strayr::read_absmap("gcc2021", remove_year_suffix = TRUE) |>
  filter(gcc_code %in% c("1GSYD", "2GMEL", "3GBRI")) |>
  select(gcc_name) |>
  st_transform(4326)

mp <- maplibre(style = carto_style("voyager"),
  bounds = gcc_lisa_map[[1]] |> filter(gcc_code == "1GSYD"),
  attributionControl = list(customAttribution = data_source))

for (nm in names(gcc_lisa_map)) {
  mp <- mp |>
    add_fill_layer(id = nm, source = gcc_lisa_map[[nm]], popup = "tp",
      fill_color = match_expr(column = "cluster",
        values = lisa_value,
        stops = lisa_color),
      fill_opacity = 0.75, fill_outline_color = "grey",
      tooltip = "sa2_name",
      hover_options = list(fill_color = "#ffd700"),
      visibility = if (nm == names(gcc_lisa_map)[1]) "visible" else "none")
}

mp <- mp |>
  add_line_layer(id = "gcc_boundary", source = gcc_boundary,
    line_color = "#222222", line_width = 2.5, line_dasharray = c(4, 2),
    tooltip = "gcc_name") |>
  add_layers_control(layers = names(gcc_lisa_map), mode = "single",
    position = "top-right", collapsible = FALSE) |>
  add_control(html = city_btn_html, position = "bottom-right", id = "city_btn") |>
  # legend titles don't wrap (nowrap + ellipsis), so keep lines short and set width
  add_categorical_legend(legend_title = "Resident workers LISA clusters<br>Top 5 industries, 3 GCCs<br>Location Quotient(LQ) by<br>place of residence, p < 0.05",
    values = lisa_value, colors = lisa_color, width = "290px",
    collapsible = TRUE, position = "top-left", style = legend_bg) |>
  add_categorical_legend(legend_title = "Boundary", values = "Greater Capital City (GCCSA)",
    colors = "#222222", patch_shape = "line", width = "290px",
    add = TRUE, position = "top-left", style = legend_bg) |>
  # custom controls are created after map load, so delegate clicks from el;
  # the summary table is appended to el directly and made draggable by its <summary>
  htmlwidgets::onRender("function(el, x, data) {
    el.addEventListener('click', e => {
      const b = e.target.closest('.city-btn');
      if (b) el.map.fitBounds(JSON.parse(b.dataset.bounds), {padding: 20});
    });

    const box = document.createElement('div');
    box.innerHTML = data.tbl;
    box.style.cssText = 'position:absolute; left:10px; bottom:30px; z-index:5;';
    el.appendChild(box);

    const handle = box.querySelector('.drag-handle');
    let moved = false;
    handle.addEventListener('mousedown', e => {
      const sx = e.clientX, sy = e.clientY, ox = box.offsetLeft, oy = box.offsetTop;
      moved = false;
      const mv = ev => {
        if (Math.abs(ev.clientX - sx) + Math.abs(ev.clientY - sy) > 3) moved = true;
        box.style.left = ox + ev.clientX - sx + 'px';
        box.style.top = oy + ev.clientY - sy + 'px';
        box.style.bottom = 'auto';
      };
      const up = () => {
        document.removeEventListener('mousemove', mv);
        document.removeEventListener('mouseup', up);
      };
      document.addEventListener('mousemove', mv);
      document.addEventListener('mouseup', up);
      e.preventDefault();
      e.stopPropagation();
    });
    handle.addEventListener('click', e => { if (moved) e.preventDefault(); });
  }", data = list(tbl = top5_tbl_html))

htmlwidgets::saveWidget(mp, "maps/day4_3gcc_top5_lisa.html", selfcontained = TRUE)
