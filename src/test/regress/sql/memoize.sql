-- Perform tests on the Memoize node.

-- The cache hits/misses/evictions from the Memoize node can vary between
-- machines.  Let's just replace the number with an 'N'.  In order to allow us
-- to perform validation when the measure was zero, we replace a zero value
-- with "Zero".  All other numbers are replaced with 'N'.
create function explain_memoize(query text, hide_hitmiss bool) returns setof text
language plpgsql as
$$
declare
    ln text;
begin
    for ln in
        execute format('explain (analyze, costs off, summary off, timing off, buffers off) %s',
            query)
    loop
        if hide_hitmiss = true then
                ln := regexp_replace(ln, 'Hits: 0', 'Hits: Zero');
                ln := regexp_replace(ln, 'Hits: \d+', 'Hits: N');
                ln := regexp_replace(ln, 'Misses: 0', 'Misses: Zero');
                ln := regexp_replace(ln, 'Misses: \d+', 'Misses: N');
        end if;
        ln := regexp_replace(ln, 'Evictions: 0', 'Evictions: Zero');
        ln := regexp_replace(ln, 'Evictions: \d+', 'Evictions: N');
        ln := regexp_replace(ln, 'Memory Usage: \d+', 'Memory Usage: N');
        ln := regexp_replace(ln, 'Heap Fetches: \d+', 'Heap Fetches: N');
        ln := regexp_replace(ln, 'loops=\d+', 'loops=N');
        ln := regexp_replace(ln, 'Index Searches: \d+', 'Index Searches: N');
        ln := regexp_replace(ln, 'Memory: \d+kB', 'Memory: NkB');
        return next ln;
    end loop;
end;
$$;

-- Ensure we get a memoize node on the inner side of the nested loop
SET enable_hashjoin TO off;
SET enable_bitmapscan TO off;

SELECT explain_memoize('
SELECT COUNT(*),AVG(t1.unique1) FROM tenk1 t1
INNER JOIN tenk1 t2 ON t1.unique1 = t2.twenty
WHERE t2.unique1 < 1000;', false);

-- And check we get the expected results.
SELECT COUNT(*),AVG(t1.unique1) FROM tenk1 t1
INNER JOIN tenk1 t2 ON t1.unique1 = t2.twenty
WHERE t2.unique1 < 1000;

-- Try with LATERAL joins
SELECT explain_memoize('
SELECT COUNT(*),AVG(t2.unique1) FROM tenk1 t1,
LATERAL (SELECT t2.unique1 FROM tenk1 t2
         WHERE t1.twenty = t2.unique1 OFFSET 0) t2
WHERE t1.unique1 < 1000;', false);

-- And check we get the expected results.
SELECT COUNT(*),AVG(t2.unique1) FROM tenk1 t1,
LATERAL (SELECT t2.unique1 FROM tenk1 t2
         WHERE t1.twenty = t2.unique1 OFFSET 0) t2
WHERE t1.unique1 < 1000;

-- Try with LATERAL joins
SELECT explain_memoize('
SELECT COUNT(*),AVG(t2.t1two) FROM tenk1 t1 LEFT JOIN
LATERAL (
    SELECT t1.two as t1two, * FROM tenk1 t2 WHERE t2.unique1 < 4 OFFSET 0
) t2
ON t1.two = t2.two
WHERE t1.unique1 < 10;', false);

-- And check we get the expected results.
SELECT COUNT(*),AVG(t2.t1two) FROM tenk1 t1 LEFT JOIN
LATERAL (
    SELECT t1.two as t1two, * FROM tenk1 t2 WHERE t2.unique1 < 4 OFFSET 0
) t2
ON t1.two = t2.two
WHERE t1.unique1 < 10;

-- Try with LATERAL references within PlaceHolderVars
SELECT explain_memoize('
SELECT COUNT(*), AVG(t1.twenty) FROM tenk1 t1 LEFT JOIN
LATERAL (SELECT t1.two+1 AS c1, t2.unique1 AS c2 FROM tenk1 t2) s ON TRUE
WHERE s.c1 = s.c2 AND t1.unique1 < 1000;', false);

-- And check we get the expected results.
SELECT COUNT(*), AVG(t1.twenty) FROM tenk1 t1 LEFT JOIN
LATERAL (SELECT t1.two+1 AS c1, t2.unique1 AS c2 FROM tenk1 t2) s ON TRUE
WHERE s.c1 = s.c2 AND t1.unique1 < 1000;

-- Ensure we do not omit the cache keys from PlaceHolderVars
SELECT explain_memoize('
SELECT COUNT(*), AVG(t1.twenty) FROM tenk1 t1 LEFT JOIN
LATERAL (SELECT t1.twenty AS c1, t2.unique1 AS c2, t2.two FROM tenk1 t2) s
ON t1.two = s.two
WHERE s.c1 = s.c2 AND t1.unique1 < 1000;', false);

-- And check we get the expected results.
SELECT COUNT(*), AVG(t1.twenty) FROM tenk1 t1 LEFT JOIN
LATERAL (SELECT t1.twenty AS c1, t2.unique1 AS c2, t2.two FROM tenk1 t2) s
ON t1.two = s.two
WHERE s.c1 = s.c2 AND t1.unique1 < 1000;

SET enable_mergejoin TO off;

-- Test for varlena datatype with expr evaluation
CREATE TABLE expr_key (x numeric, t text);
INSERT INTO expr_key (x, t)
SELECT d1::numeric, d1::text FROM (
    SELECT round((d / pi())::numeric, 7) AS d1 FROM generate_series(1, 20) AS d
) t;

-- duplicate rows so we get some cache hits
INSERT INTO expr_key SELECT * FROM expr_key;

CREATE INDEX expr_key_idx_x_t ON expr_key (x, t);
VACUUM ANALYZE expr_key;

-- Ensure we get we get a cache miss and hit for each of the 20 distinct values
SELECT explain_memoize('
SELECT * FROM expr_key t1 INNER JOIN expr_key t2
ON t1.x = t2.t::numeric AND t1.t::numeric = t2.x;', false);

DROP TABLE expr_key;

-- Reduce work_mem and hash_mem_multiplier so that we see some cache evictions
SET work_mem TO '64kB';
SET hash_mem_multiplier TO 1.0;
-- Ensure we get some evictions.  We're unable to validate the hits and misses
-- here as the number of entries that fit in the cache at once will vary
-- between different machines.
SELECT explain_memoize('
SELECT COUNT(*),AVG(t1.unique1) FROM tenk1 t1
INNER JOIN tenk1 t2 ON t1.unique1 = t2.thousand
WHERE t2.unique1 < 1200;', true);

CREATE TABLE flt (f float);
CREATE INDEX flt_f_idx ON flt (f);
INSERT INTO flt VALUES('-0.0'::float),('+0.0'::float);
ANALYZE flt;

SET enable_seqscan TO off;

-- Ensure memoize operates in logical mode
SELECT explain_memoize('
SELECT * FROM flt f1 INNER JOIN flt f2 ON f1.f = f2.f;', false);

-- Ensure memoize operates in binary mode
SELECT explain_memoize('
SELECT * FROM flt f1 INNER JOIN flt f2 ON f1.f >= f2.f;', false);

DROP TABLE flt;

-- Exercise Memoize in binary mode with a large fixed width type and a
-- varlena type.
CREATE TABLE strtest (n name, t text);
CREATE INDEX strtest_n_idx ON strtest (n);
CREATE INDEX strtest_t_idx ON strtest (t);
INSERT INTO strtest VALUES('one','one'),('two','two'),('three',repeat(fipshash('three'),100));
-- duplicate rows so we get some cache hits
INSERT INTO strtest SELECT * FROM strtest;
ANALYZE strtest;

-- Ensure we get 3 hits and 3 misses
SELECT explain_memoize('
SELECT * FROM strtest s1 INNER JOIN strtest s2 ON s1.n >= s2.n;', false);

-- Ensure we get 3 hits and 3 misses
SELECT explain_memoize('
SELECT * FROM strtest s1 INNER JOIN strtest s2 ON s1.t >= s2.t;', false);

DROP TABLE strtest;

-- Ensure memoize works with partitionwise join
SET enable_partitionwise_join TO on;

CREATE TABLE prt (a int) PARTITION BY RANGE(a);
CREATE TABLE prt_p1 PARTITION OF prt FOR VALUES FROM (0) TO (10);
CREATE TABLE prt_p2 PARTITION OF prt FOR VALUES FROM (10) TO (20);
INSERT INTO prt VALUES (0), (0), (0), (0);
INSERT INTO prt VALUES (10), (10), (10), (10);
CREATE INDEX iprt_p1_a ON prt_p1 (a);
CREATE INDEX iprt_p2_a ON prt_p2 (a);
ANALYZE prt;

SELECT explain_memoize('
SELECT * FROM prt t1 INNER JOIN prt t2 ON t1.a = t2.a;', false);

-- Ensure memoize works with parameterized union-all Append path
SET enable_partitionwise_join TO off;

SELECT explain_memoize('
SELECT * FROM prt_p1 t1 INNER JOIN
(SELECT * FROM prt_p1 UNION ALL SELECT * FROM prt_p2) t2
ON t1.a = t2.a;', false);

DROP TABLE prt;

RESET enable_partitionwise_join;

-- Exercise Memoize code that flushes the cache when a parameter changes which
-- is not part of the cache key.

-- Ensure we get a Memoize plan
EXPLAIN (COSTS OFF)
SELECT unique1 FROM tenk1 t0
WHERE unique1 < 3
  AND EXISTS (
	SELECT 1 FROM tenk1 t1
	INNER JOIN tenk1 t2 ON t1.unique1 = t2.hundred
	WHERE t0.ten = t1.twenty AND t0.two <> t2.four OFFSET 0);

-- Ensure the above query returns the correct result
SELECT unique1 FROM tenk1 t0
WHERE unique1 < 3
  AND EXISTS (
	SELECT 1 FROM tenk1 t1
	INNER JOIN tenk1 t2 ON t1.unique1 = t2.hundred
	WHERE t0.ten = t1.twenty AND t0.two <> t2.four OFFSET 0);

RESET enable_seqscan;
RESET enable_mergejoin;
RESET work_mem;
RESET hash_mem_multiplier;
RESET enable_bitmapscan;
RESET enable_hashjoin;

-- Test parallel plans with Memoize
SET min_parallel_table_scan_size TO 0;
SET parallel_setup_cost TO 0;
SET parallel_tuple_cost TO 0;
SET max_parallel_workers_per_gather TO 2;

-- Ensure we get a parallel plan.
EXPLAIN (COSTS OFF)
SELECT COUNT(*),AVG(t2.unique1) FROM tenk1 t1,
LATERAL (SELECT t2.unique1 FROM tenk1 t2 WHERE t1.twenty = t2.unique1) t2
WHERE t1.unique1 < 1000;

-- And ensure the parallel plan gives us the correct results.
SELECT COUNT(*),AVG(t2.unique1) FROM tenk1 t1,
LATERAL (SELECT t2.unique1 FROM tenk1 t2 WHERE t1.twenty = t2.unique1) t2
WHERE t1.unique1 < 1000;

RESET max_parallel_workers_per_gather;
RESET parallel_tuple_cost;
RESET parallel_setup_cost;
RESET min_parallel_table_scan_size;

-- Ensure memoize works for ANTI joins
CREATE TABLE tab_anti (a int, b boolean);
INSERT INTO tab_anti SELECT i%3, false FROM generate_series(1,100)i;
ANALYZE tab_anti;

-- Ensure we get a Memoize plan for ANTI join
SELECT explain_memoize('
SELECT COUNT(*) FROM tab_anti t1 LEFT JOIN
LATERAL (SELECT DISTINCT ON (a) a, b, t1.a AS x FROM tab_anti t2) t2
ON t1.a+1 = t2.a
WHERE t2.a IS NULL;', false);

-- And check we get the expected results.
SELECT COUNT(*) FROM tab_anti t1 LEFT JOIN
LATERAL (SELECT DISTINCT ON (a) a, b, t1.a AS x FROM tab_anti t2) t2
ON t1.a+1 = t2.a
WHERE t2.a IS NULL;

-- Ensure we do not add memoize node for SEMI join
EXPLAIN (COSTS OFF)
SELECT * FROM tab_anti t1 WHERE t1.a IN
 (SELECT a FROM tab_anti t2 WHERE t2.b IN
  (SELECT t1.b FROM tab_anti t3 WHERE t2.a > 1 OFFSET 0));

DROP TABLE tab_anti;
