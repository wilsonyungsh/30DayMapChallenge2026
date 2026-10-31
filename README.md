# 30DayMapChallenges2026

Data and mapping works for the [#30DayMapChallenge](https://30daymapchallenge.com/) 2026.

| Day | Theme | Map | Script |
|-----|-------|-----|--------|
| 1 | Points | [Australia 2026 Meshblocks by Land Use](https://wilsonyungsh.github.io/interactive/30DayMapChallenge2026/day1_aus26_mb.html) | [Day1_abs_census_mb_pt.r](scripts/Day1_abs_census_mb_pt.r) |

---

## Day 1 – Points: Australia's 2026 Census Meshblocks

🗺️ **[Open the interactive map](https://wilsonyungsh.github.io/interactive/30DayMapChallenge2026/day1_aus26_mb.html)**

2026 is an Australian Census year, so Day 1 starts with the smallest building block of the census geography: the **Mesh Block (MB)** from the ABS Australian Statistical Geography Standard (ASGS) 2026.

### What's on the map

- **Points**: each of the 374,803 Mesh Blocks is shown as a single point at its centroid.
- **Colour**: land use category of the Mesh Block. Education, Hospital/Medical and Transport are grouped as *Infrastructure*.
- **Point size**: scaled by the (log) number of Mesh Blocks in that land use category Australia-wide.
- **Popup**: Mesh Block code, SA2 name and land use.
- **Summary table**: Australia-wide Mesh Block count and area, with each land use's share of the total.

### Count vs area: two very different pictures

| Land use | MB count | MB % | Area (km²) | Area % |
|---|---:|---:|---:|---:|
| Primary Production | 19,323 | 5.2% | 5,905,352 | 76.8% |
| Other | 5,170 | 1.4% | 1,055,421 | 13.7% |
| Parkland | 62,561 | 16.7% | 646,073 | 8.4% |
| Water | 4,421 | 1.2% | 41,978 | 0.5% |
| Residential | 248,975 | 66.4% | 33,572 | 0.4% |
| Industrial | 7,730 | 2.1% | 3,520 | <0.1% |
| Infrastructure | 11,500 | 3.1% | 1,230 | <0.1% |
| Commercial | 15,123 | 4.0% | 949 | <0.1% |
| **Total** | **374,803** | **100%** | **7,688,095** | **100%** |

Mesh Blocks are designed to hold roughly similar numbers of dwellings, so they are tiny where people live and vast where they don't:

- **Residential** Mesh Blocks make up **two-thirds of all Mesh Blocks (66.4%)** but cover only **0.4% of the land**.
- **Primary Production** Mesh Blocks are only **5.2% of the count** but cover **over three-quarters (76.8%) of Australia**.

Counted by Mesh Block, Australia looks residential. Measured by area, it's farmland and outback. Plotting centroids makes this visible: points crowd into the cities and coast, and thin out to a sparse scatter across the interior.

### Data & tools

- **Data**: ABS ASGS Edition 2026 Mesh Blocks, via the `abs.geo` R package. Area is the ABS-supplied `area_albers_sqkm`.
- **Mapping**: [`mapgl`](https://walker-data.com/mapgl/) (MapLibre GL JS) in R, exported with `htmlwidgets`.
- **Script**: [scripts/Day1_abs_census_mb_pt.r](scripts/Day1_abs_census_mb_pt.r)
