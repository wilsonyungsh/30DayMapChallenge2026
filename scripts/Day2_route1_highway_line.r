pacman::p_load(tidyverse, sf, DBI, duckdb, duckspatial, mapgl, osmdata, abs.geo)

con <- dbConnect(drv = duckdb())
dbExecute(con, "load spatial")
dbExecute(con, "load httpfs")
dbExecute(con, "load json")
dbExecute(con, "SET s3_region = 'us-west-2'")
# dbExecute(con, "SET VARIABLE latest = (
#     SELECT latest FROM 'https://stac.overturemaps.org/catalog.json'
# );")


# check latest overturemap catalog version
catalog <- dbGetQuery(con, "SELECT latest FROM 'https://stac.overturemaps.org/catalog.json';")

# bbox from openstreetmap

bb <- osmdata::getbb(place_name = "Australia")

# get aus wide water transport routes and filter to aus only
df <- dbGetQuery(con, glue::glue(readr::read_file("sql/road_extract_query.sql"),
  xmin = bb[1, 1],
  xmax = bb[1, 2],
  ymin = bb[2, 1],
  ymax = bb[2, 2],
  latest = unname(catalog))) |>
  st_as_sf(crs = 4326)

aus <- get_asgs26_geo(level = "STE") |> st_transform(4326) |> filter(!is.na(area_albers_sqkm)) |>
  select(state_name_2026) |> rename(state = state_name_2026)

overture_water_au <- df |> st_join(aus, left = FALSE) |>
  mutate(length_km = round(as.numeric(st_length(geometry)) / 1000, 4),
    tp = imap(across(c(name, state, length_km)), ~ paste0("<b>", .y, ": </b>", .x)) |> pmap_chr(paste, sep = "<br>"))

# summary table
route_summary <-
  overture_water_au |>  st_drop_geometry() |>
  group_by(state) |> reframe(cnt = n(), total_route_length_km = sum(length_km)) |>
  arrange(desc(cnt), desc(total_route_length_km))

top_10_length_route <-
  overture_water_au |>  st_drop_geometry() |> filter(!is.na(name)) |>
  arrange(desc(length_km)) |> select(name, state, length_km) |>
  head(10)


## summary panels
panel_style <- "background:rgba(20,20,20,.85);color:#eee;padding:8px 10px;border-radius:4px;font:12px sans-serif;box-shadow:0 1px 4px rgba(0,0,0,.5);max-height:45vh;overflow:auto"

state_rows <- route_summary |>
  glue::glue_data(
    "<tr><td>{state}</td>",
    "<td style='text-align:right'>{scales::comma(cnt)}</td>",
    "<td style='text-align:right'>{scales::comma(total_route_length_km, accuracy = 0.1)}</td></tr>"
  ) |> paste(collapse = "")

top10_rows <- top_10_length_route |>
  mutate(rank = row_number()) |>
  glue::glue_data(
    "<tr><td>{rank}</td><td>{name}</td><td>{state}</td>",
    "<td style='text-align:right'>{scales::comma(length_km, accuracy = 0.1)}</td></tr>"
  ) |> paste(collapse = "")

summary_html <- paste0(
  "<div style='", panel_style, "'>",
  "<details open><summary style='cursor:pointer;font-weight:bold'>Water routes by state</summary>",
  "<table style='border-collapse:collapse;margin-top:4px'>",
  "<tr style='border-bottom:1px solid #555'><th style='text-align:left'>State</th><th>Routes</th><th>Length (km)</th></tr>",
  state_rows,
  "<tr style='border-top:1px solid #555;font-weight:bold'><td>Total</td>",
  "<td style='text-align:right'>", scales::comma(sum(route_summary$cnt)), "</td>",
  "<td style='text-align:right'>", scales::comma(sum(route_summary$total_route_length_km), accuracy = 0.1), "</td></tr>",
  "</table></details></div>"
)

top10_html <- paste0(
  "<div style='", panel_style, "'>",
  "<details close><summary style='cursor:pointer;font-weight:bold'>Top 10 longest named routes</summary>",
  "<table style='border-collapse:collapse;margin-top:4px'>",
  "<tr style='border-bottom:1px solid #555'><th>#</th><th style='text-align:left'>Name</th><th style='text-align:left'>State</th><th>Length (km)</th></tr>",
  top10_rows,
  "</table></details></div>"
)

## vis
berowra_water_ferry <- c(151.12350106526856, -33.60010762936818)
map <-
  maplibre(style = carto_style(style_name = "dark-matter"), bounds = overture_water_au, pitch = 35) |>
  add_line_layer(source = overture_water_au, id = "aus_water", line_color = "blue",
    line_width = 3.5, popup = "tp") |>
  add_categorical_legend(legend_title = "Australia Water Transport Route<br>(From OvertureMaps)",
    colors = "blue", values = "Water Transport Routes") |>
  add_control(html = summary_html, position = "bottom-left", id = "summary") |>
  add_control(html = top10_html, position = "bottom-right", id = "top10") |>
  fly_to(center = berowra_water_ferry, zoom = 14)

htmlwidgets::saveWidget(map, file = "day2_aus_water_routes.html", selfcontained = TRUE)
