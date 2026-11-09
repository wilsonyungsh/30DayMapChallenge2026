pacman::p_load(tidyverse, sf, janitor, mapgl, httr, stringr, purrr)

# ---- 1. 非都市土地使用分區（Rural）-------------------------------------------
kh_rural_url <- "https://odportal.tw/api/v1/resource/PApBXu7q/66f8c531bae5da001973f40a"
if (!file.exists("./data/kh_rural_uses.zip")) {
  curl::curl_download(url = kh_rural_url, destfile = "./data/kh_rural_uses.zip")
  unzip("./data/kh_rural_uses.zip", exdir = "./data/kh_rural_uses")
}
kh_rural <- st_read("data/kh_rural_uses/非都市土地使用分區_高雄市.shp")

# ---- 2. 高雄市都市計畫區（Urban）---------------------------------------------
# 來源：https://urbangisdata.kcg.gov.tw/ODA/web_page/ODA020100.jsp
base_url <- "https://urbangisdata.kcg.gov.tw/ODA"
out_dir  <- "data/urban_plan"
zip_dir  <- file.path(out_dir, "zip")
shp_dir  <- file.path(out_dir, "shp")
walk(c(zip_dir, shp_dir), dir.create, recursive = TRUE, showWarnings = FALSE)

h <- handle(base_url) # 同一個 handle 才會保留 session cookie

get_page <- function(p) {
  res <- POST(
    file.path(base_url, "web_page/ODA020100.jsp"),
    body = list(PNO01 = p, sendurl = "ODA020100",
      ODA001004 = "", ODA001007 = "", csrf_token = ""),
    encode = "form", handle = h
  )
  html <- content(res, "text", encoding = "UTF-8")
  # 頁面的 <tr> 沒有 </tr>，用字串切割比 HTML parser 穩
  rows <- str_split(html, '<tr align="center">')[[1]][-1]
  rows <- rows[str_detect(rows, "DLSF")]
  m <- str_match(rows, "DLSF\\('[^']*','[^']*','(\\w+)','(\\w+)','([^']+)'")
  tibble(name = str_match(rows, "<td>(.*?)</td>")[, 2],
    pk01 = m[, 2], pk02 = m[, 3], pk03 = m[, 4])
}

up_gpkg <- file.path(out_dir, "urban_plan_all.gpkg")

if (!file.exists(up_gpkg)) {
  # 總頁數
  n_pages <- POST(file.path(base_url, "web_page/ODA020100.jsp"),
    body = list(PNO01 = 1, sendurl = "ODA020100", csrf_token = ""),
    encode = "form", handle = h) |>
    content("text", encoding = "UTF-8") |>
    str_extract_all('<option value="(\\d+)"') |> unlist() |>
    str_extract("\\d+") |> as.integer() |> max()

  links <- map_dfr(seq_len(n_pages), get_page)
  message("共 ", nrow(links), " 筆")

  # 下載 zip
  download_one <- function(pk01, pk02, pk03) {
    dest <- file.path(zip_dir, pk03)
    if (!file.exists(dest)) {
      POST(file.path(base_url, "web_script/downloadfile.jsp"),
        body = list(PK01 = pk01, PK02 = pk02, PK03 = pk03),
        encode = "form", handle = h,
        write_disk(dest, overwrite = TRUE), timeout(300))
      Sys.sleep(0.5)
    }
    dest
  }
  links$zip <- pmap_chr(links[c("pk01", "pk02", "pk03")], download_one)

  # zip 內的檔名是 Big5，R 的 unzip() 會 error -1（只有檔名剛好相容的 2 個能解開），
  # 所以改用 macOS 內建的 ditto；其他系統可改用 7z / bsdtar
  unzip_one <- function(z, id) {
    exdir <- file.path(shp_dir, id)
    dir.create(exdir, showWarnings = FALSE)
    status <- system2("ditto", c("-x", "-k", shQuote(z), shQuote(exdir)))
    if (status != 0) stop("解壓縮失敗：", z)
  }
  walk2(links$zip, links$pk02, unzip_one)

  # 合併：欄位不一致 -> bind_rows 補 NA；編碼交給各 shp 的 .cpg 決定
  read_plan <- function(id, name) {
    shp <- list.files(file.path(shp_dir, id), pattern = "\\.shp$",
      recursive = TRUE, full.names = TRUE, ignore.case = TRUE)
    map_dfr(shp, \(f) {
      x <- st_read(f, quiet = TRUE)
      if (is.na(st_crs(x))) st_crs(x) <- 3826 # 缺投影時假設 TWD97 / TM2
      st_transform(x, 3826) |>
        mutate(across(-geometry, as.character),
          plan_name = name, src_file = basename(f), .before = 1)
    })
  }
  all_plan <- map2_dfr(links$pk02, links$name, read_plan) |> st_as_sf()
  st_write(all_plan, up_gpkg, delete_dsn = TRUE, quiet = TRUE)
}

up <- st_read(up_gpkg) |> filter(plan_name != "高雄市更新地區範圍圖")

# ---- 3. 看圖 -----------------------------------------------------------------
# 兩個來源的幾何欄位名稱不同（up: geom / kh_rural: geometry），bind_rows 不會合併，
# 所以先統一欄名、只留共同欄位，並統一轉成 MULTIPOLYGON
kh <- bind_rows(
  up |>
    st_set_geometry("geometry") |>
    select(plan_name, NAME, AREA) |>
    mutate(AREA = as.integer(AREA)),
  kh_rural |>
    mutate(plan_name = "非都市土地使用",
      NAME = 使用分,
      AREA = as.integer(st_area(geometry)))
) |>
  st_cast("MULTIPOLYGON") |>
  clean_names() |>
  # 台灣國土計畫體系：第一層 都市 / 非都市；都市計畫再分 主要計畫、都市計畫、特定區計畫
  mutate(
    land_type = if_else(plan_name == "非都市土地使用", "Rural", "Urban"),
    plan_type = case_when(
      land_type == "Rural"              ~ "Non-urban Land Use",
      str_detect(plan_name, "主要計畫")   ~ "Master Plan",
      str_detect(plan_name, "特定區計畫") ~ "Special District Plan",
      str_detect(plan_name, "都市計畫")   ~ "Urban Plan"
  )) |>
  group_by(land_type, plan_type, plan_name, name) |> summarise(area = sum(area))

kh_consolidated <- kh |> group_by(land_type, plan_type) |> summarise(unique_plan_cnt = n_distinct(plan_name),
  unique_zone_cnt = n_distinct(name))
maplibre_view(kh, column = "plan_name")

value <- c("Master Plan", "Urban Plan", "Special District Plan", "Non-urban Land Use")
color <- c("#f5c542", "#42bff5", "#de8a14", "#14deb2") # 順序要和 value 一致
value_zh <- c("主要計畫", "都市計畫", "特定區計畫", "非都市土地使用分區")

# ---- 4. Summary table（中英對照）---------------------------------------------
summary_tbl <- kh_consolidated |>
  st_drop_geometry() |>
  ungroup() |>
  mutate(zh = value_zh[match(plan_type, value)],
    col = color[match(plan_type, value)],
    land_zh = if_else(land_type == "Urban", "都市土地", "非都市土地")) |>
  arrange(match(plan_type, value))

rows_html <- summary_tbl |>
  mutate(html = str_glue(
    "<tr><td><span style='display:inline-block;width:10px;height:10px;background:{col};",
    "margin-right:6px;'></span>{plan_type}<br><small>{zh}</small></td>",
    "<td style='text-align:center'>{land_type}<br><small>{land_zh}</small></td>",
    "<td style='text-align:right'>{unique_plan_cnt}</td>",
    "<td style='text-align:right'>{unique_zone_cnt}</td></tr>")) |>
  pull(html) |> paste(collapse = "")

# 行內事件：add_control 用 innerHTML 放入 HTML，<script> 不會執行，但 onxxx 屬性可以
drag_js <- "(function(e,h){var w=h.parentNode,x=e.clientX-(parseFloat(w.dataset.x)||0),y=e.clientY-(parseFloat(w.dataset.y)||0);h.setPointerCapture(e.pointerId);h.onpointermove=function(m){var a=m.clientX-x,b=m.clientY-y;w.dataset.x=a;w.dataset.y=b;w.style.transform='translate('+a+'px,'+b+'px)'};h.onpointerup=function(){h.onpointermove=null}})(event,this)"
toggle_js <- "var b=this.parentNode.nextElementSibling,c=b.style.display==='none';b.style.display=c?'block':'none';this.textContent=c?'−':'+'"

summary_html <- str_glue(
  "<div style='background:rgba(255,255,255,.92);padding:10px 12px;border-radius:6px;",
  "font:12px/1.4 sans-serif;box-shadow:0 1px 4px rgba(0,0,0,.3);'>",
  # 標題列：拖曳把手 + 收合按鈕
  "<div onpointerdown=\"{drag_js}\" style='display:flex;justify-content:space-between;",
  "gap:12px;cursor:move;touch-action:none;user-select:none;'>",
  "<b>Kaohsiung Planning Framework 高雄市土地計畫架構</b>",
  "<span onpointerdown='event.stopPropagation()' onclick=\"{toggle_js}\" ",
  "title='Collapse / expand 收合' style='cursor:pointer;font-weight:bold;padding:0 4px;'>−</span></div>",
  "<div>",
  "<table style='border-collapse:collapse;margin-top:6px;'>",
  "<tr style='border-bottom:1px solid #999;'><th>Plan type<br>計畫類型</th>",
  "<th>Land<br>土地</th><th>Plans<br>計畫區數</th><th>Zone types<br>分區種類</th></tr>",
  "{rows_html}</table>",
  "<div style='margin-top:8px;font-size:10px;color:#555;max-width:330px;'>",
  "<b>Source 資料來源</b><br>",
  "Urban 都市計畫：Kaohsiung City Government Urban Development Bureau, ",
  "Open Data Platform 高雄市政府都市發展局資料開放平台 (urbangisdata.kcg.gov.tw)<br>",
  "Rural 非都市土地使用分區：Kaohsiung non-urban land use zones 高雄市非都市土地使用分區, ",
  "Open Data Portal (odportal.tw)</div></div></div>")

kh_loc <- c(120.41882448888451, 22.804975860748105)
maplibre(center = kh_loc, zoom = 8) |>
  add_fill_layer(id = "plan_type", source = kh_consolidated,
    fill_color = match_expr("plan_type", values = value,
      stops = color), fill_opacity = 0.5) |>
  add_categorical_legend(legend_title = "Land Use Type 土地計畫類型",
    colors = color, values = paste(value, value_zh),
    draggable = TRUE, collapsible = TRUE) |>
  add_control(html = as.character(summary_html), position = "bottom-left") |>
  add_globe_minimap(position = "bottom-right", globe_size = 100)
