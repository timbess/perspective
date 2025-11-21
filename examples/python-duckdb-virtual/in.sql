
WITH symbol_sums AS (
    SELECT 
        division,
        symbol,
        SUM(mv) AS mv_sum,
        SUM(SUM(mv)) OVER (PARTITION BY symbol) AS symbol_total_across_divisions,
        ROW_NUMBER() OVER (PARTITION BY symbol ORDER BY division) AS symbol_row_num,
    FROM data_source_one
    GROUP BY division, symbol
)

SELECT 
    CASE 
        WHEN GROUPING(division) = 1 AND GROUPING(symbol) = 1 THEN
            -- Total
            SUM(CASE WHEN symbol_row_num = 1 THEN ABS(symbol_total_across_divisions) ELSE 0 END)
        WHEN GROUPING(symbol) = 1 THEN
            -- Intermediate Rollup
            SUM(ABS(mv_sum))
        ELSE
            -- Leaf
            ABS(SUM(mv_sum))
    END AS MV,
    division AS __ROW_PATH_0__,
    symbol AS __ROW_PATH_1__,
    GROUPING_ID(division, symbol) AS __GROUPING_ID__
FROM symbol_sums
GROUP BY ROLLUP(division, symbol)
ORDER BY 
    GROUPING(division) DESC,
    __ROW_PATH_0__ ASC,
    GROUPING_ID(division, symbol) DESC,
    __ROW_PATH_1__ ASC

