select id,names.primary as name,subtype,geometry from read_parquet(
's3://overturemaps-us-west-2/release/{latest}/theme=transportation/type=segment/*'
) where subtype = 'water' and bbox.xmin> {xmin} and bbox.xmax<{xmax} and 
bbox.ymin>{ymin} and bbox.ymax<{ymax}