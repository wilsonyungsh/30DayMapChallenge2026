pacman::p_load(tidyverse, sf, mapgl, osmdata, geodata, httr2)

# Taiwan land boundary
tw_land <- geodata::gadm(country = "TWN", path = "tw_sf", level = 2) |>
  st_as_sf() |>
  select(ENGTYPE_2, NAME_2, NL_NAME_2)


# Taiwan National Park Boundaries
np_names <- c("陽明山國家公園", "雪霸國家公園", "太魯閣國家公園", "玉山國家公園",
  "墾丁國家公園", "金門國家公園", "東沙環礁國家公園", "台江國家公園",
  "澎湖南方四島國家公園", "壽山國家自然公園")

get_np <- function(nm) {
  Sys.sleep(1)  # Nominatim usage policy: max 1 req/sec
  request("https://nominatim.openstreetmap.org/search") |>
    req_url_query(q = nm, format = "geojson", polygon_geojson = 1, limit = 1) |>
    req_user_agent("30DayMapChallenge2026 (wilsonyungsh)") |>
    req_perform() |>
    resp_body_string() |>
    st_read(quiet = TRUE)
}

tw_np <- map(np_names, get_np) |> bind_rows() |>
  select(name)

tw_np_area <- tw_np |> st_transform(32651) |>
  mutate(areasqkm = round(as.numeric(st_area(geometry) / 10^6), 3),    tp = imap(across(c(name, areasqkm)), ~ paste0("<b>", .y, ":</b>", .x)) |>
    pmap_chr(paste, sep = "<br>")) |>
  st_transform(4326)
tw_np_table <- tw_np_area |> st_drop_geometry() |> select(name, areasqkm) |> arrange(desc(areasqkm))

# collapsible html table for the map
np_table_html <- paste0(
  '<details open style="background:white; padding:6px 10px; border-radius:4px;',
  ' font-family:sans-serif; font-size:12px; max-height:60vh; overflow-y:auto;">',
  '<summary style="font-weight:bold; cursor:pointer;">National Parks</summary>',
  '<table style="border-collapse:collapse; margin-top:4px;">',
  '<tr><th style="text-align:left; padding:2px 8px;">Name</th>',
  '<th style="text-align:right; padding:2px 8px;">Area (km²)</th></tr>',
  paste0('<tr><td style="padding:2px 8px;">', tw_np_table$name, "</td>",
    '<td style="text-align:right; padding:2px 8px;">',
    format(tw_np_table$areasqkm, big.mark = ",", nsmall = 1), "</td></tr>",
    collapse = ""),
  "</table></details>")
# taiwan boundary including ocean

tw_incl_ocean <- get_np(nm = "taiwan")


## Vis
view_pt <- c(119.03238611225783, 22.638380171520478)
land_value <- c("Special Municipality", "Provincial City", "County")
land_value_color <- c("#34eb83", "#cc6b21",  "#610fdb")
legend_bg <- legend_style(background_color = "white", background_opacity = 1)


maplibre(zoom = 5, pitch = 50, bearing = -15, center = view_pt,
  projection = "mercator") |>
  add_line_layer(id = "tw_whole_boundary",
    source = tw_incl_ocean |> st_boundary(),
    line_color = "blue", line_dasharray = c(6, 3), line_width = 2, line_cap = "round") |>
  add_fill_layer(id = "tw_land", source = tw_land, popup = "NL_NAME_2",
    hover_options = list(fill_color = "red"),
    fill_color = match_expr(column = "ENGTYPE_2",
      values = land_value,
      stops = land_value_color),
    fill_opacity = 0.6, fill_outline_color = "black") |>
  add_fill_extrusion_layer(id = "np", source = tw_np_area, popup = "tp",
    fill_extrusion_height = 5 * 10^4,
    fill_extrusion_color = mapgl::interpolate(column = "areasqkm",
      values = c(0, 500, 4000),
      stops = c("#c7e9c0", "#41ab5d", "#00441b")),
    fill_extrusion_opacity = 0.85,
    tooltip = "name",
    hover_options = list(fill_extrusion_color = "#ffd700")) |>
  add_categorical_legend(legend_title = "Level of City <br>(population decending)",
    colors = land_value_color, values = land_value,
    collapsible = TRUE, position = "top-left", style = legend_bg) |>
  add_continuous_legend(legend_title = "National Park Area (km²)",
    values = c("0", "500", "4,000"),
    colors = c("#c7e9c0", "#41ab5d", "#00441b"),
    draggable  = TRUE, position = "bottom-left", add = TRUE, interactive = TRUE, layer_id = "np",
    filter_column = "areasqkm", filter_values = c(0, 500, 4000), collapsible = TRUE,
    style = legend_bg) |>
  add_control(html = np_table_html, position = "top-right", id = "summary_tbl")
