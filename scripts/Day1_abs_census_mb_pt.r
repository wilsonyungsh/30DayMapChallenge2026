pacman::p_load(tidyverse, sf, abs.geo, mapgl)

abs_mb_26_centroid <- get_asgs26_geo(level = "mb") |> filter(!is.na(area_albers_sqkm)) |>
  select(mb_code_2026, mb_category_2026, contains("name"), area_albers_sqkm) |>
  st_centroid() |>
  mutate(lu = ifelse(mb_category_2026 %in% c("Education", "Hospital/Medical", "Transport"), "Infrastructure", mb_category_2026))

# 1. Define the named vector lookup
land_use_palette <- c(
  "Parkland"           = "#A1D99B",  # Light Green
  "Other"              = "#E0E0E0",  # Light Warm Grey
  "Primary Production" = "#8F9E7B",  # Olive / Muted Green
  "Residential"        = "#FDD49E",  # Warm Yellow
  "Infrastructure"     = "#969696",  # Cool Grey (Standard for civic/infra utilities)
  "Commercial"         = "#EF3B2C",  # Red / Coral
  "Industrial"         = "#BCBDDC",  # Purple / Violet
  "Water"              = "#9ECAE1"   # Soft Blue
)

# Match color and produce reference

size_ref <-
  abs_mb_26_centroid |> st_drop_geometry() |>
  group_by(lu) |> reframe(areasqkm = sum(area_albers_sqkm), mb_cnt = n()) |>
  arrange(desc(areasqkm)) |>
  mutate(hex_code = land_use_palette[lu],
    cnt_norm = scales::rescale(log(mb_cnt), to = c(0, 1)))

mb_sf <- abs_mb_26_centroid |> left_join(size_ref, by = "lu") |>
  rename_with(.cols = c(mb_code_2026, sa2_name_2026), ~ str_remove_all(.x, "_2026")) |>
  mutate(
    lu_total_areasqkm = scales::comma(areasqkm, accuracy = 0.1),
    lu_mb_cnt = scales::comma(mb_cnt),
    tp = imap(across(c(mb_code, sa2_name, lu)),
      ~ paste0("<b>", .y, " : </b>", .x)) |> pmap_chr(paste, sep = "<br>"))

# Australia-wide summary table for the map panel
summary_rows <- size_ref |>
  mutate(area_pct = areasqkm / sum(areasqkm), mb_pct = mb_cnt / sum(mb_cnt)) |>
  glue::glue_data(
    "<tr><td><span style='display:inline-block;width:10px;height:10px;border-radius:50%;background:{hex_code};margin-right:6px'></span>{lu}</td>",
    "<td style='text-align:right'>{scales::comma(mb_cnt)}</td>",
    "<td style='text-align:right'>{scales::percent(mb_pct, accuracy = 0.1)}</td>",
    "<td style='text-align:right'>{scales::comma(areasqkm)}</td>",
    "<td style='text-align:right'>{scales::percent(area_pct, accuracy = 0.1)}</td></tr>"
  ) |> paste(collapse = "")

summary_html <- paste0(
  "<div style='background:white;padding:8px 10px;border-radius:4px;font:12px sans-serif;box-shadow:0 1px 4px rgba(0,0,0,.3)'>",
  "<details open><summary style='cursor:pointer;font-weight:bold'>Australia-wide Meshblocks by Land Use</summary>",
  "<table style='border-collapse:collapse;margin-top:4px'>",
  "<tr style='border-bottom:1px solid #ccc'><th style='text-align:left'>Land use</th><th>MB count</th><th>MB %</th><th>Area (km²)</th><th>Area %</th></tr>",
  summary_rows,
  "<tr style='border-top:1px solid #ccc;font-weight:bold'><td>Total</td>",
  "<td style='text-align:right'>", scales::comma(sum(size_ref$mb_cnt)), "</td><td style='text-align:right'>100%</td>",
  "<td style='text-align:right'>", scales::comma(sum(size_ref$areasqkm)), "</td><td style='text-align:right'>100%</td></tr>",
  "</table></details></div>"
)


map <-
  maplibre(bounds = mb_sf) |>
  add_circle_layer(id = "mb", source = mb_sf |> select(lu, tp), popup = "tp", circle_opacity = 0.6,
    circle_radius = match_expr(column = "lu",
      values = size_ref$lu,
      stops = scales::rescale(size_ref$cnt_norm, to = c(1.5, 8), from = c(0, 1)),
      default = 1.5),
    circle_color = match_expr(column = "lu",
      values = size_ref$lu,
      stops = size_ref$hex_code)
  ) |>
  add_categorical_legend(legend_title = "ABS Meshblock Landuse 2026<br>Simplified as Centroid", colors = size_ref$hex_code,
    values = size_ref$lu, draggable = TRUE) |>
  add_control(html = summary_html, position = "bottom-left")

htmlwidgets::saveWidget(selfcontained = TRUE, widget = map, file = "aus26_mb.html")
