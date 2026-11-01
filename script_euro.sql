-------------------------------------------------------
-- Uefa Euro (1960-2024): exploratory queries, data checks and views
-- Target: SQL Server (T-SQL). Run it against a database restored
-- from dump_euro.sql. Expected totals: 388 matches, 946 goals,
-- 566 players.
-------------------------------------------------------


-------------------------------------------------------
-- General queries on the database
-------------------------------------------------------

-- Matches decided by penalties
SELECT * FROM euro.jogos WHERE desempate = N'pênaltis' ORDER BY idjogo DESC;

-- Drawn matches outside the group stage
SELECT * FROM euro.jogos
WHERE gols_seleção1 = gols_seleção2 AND fase <> N'fase de grupos'
ORDER BY idjogo DESC;

-- Players with names containing 'kane'
SELECT * FROM euro.jogadores WHERE nome LIKE N'%kane%';

-- Most recently recorded goals
SELECT TOP 20 * FROM euro.gols ORDER BY idgol DESC;

-- Most recently registered players
SELECT TOP 20 * FROM euro.jogadores ORDER BY idjogador DESC;

-- Count of results with victory on penalties
SELECT COUNT(idresultado) AS vitorias_penaltis
FROM euro.resultados
WHERE pen_VD = 'V';

-- Goals from a specific match
SELECT * FROM euro.gols WHERE idjogo = 212;


-------------------------------------------------------
-- Data checks and validations
-- (every check below is expected to return no rows)
-------------------------------------------------------

-- Goals by players not existing in the players table
SELECT g.*
FROM euro.gols g
LEFT JOIN euro.jogadores j ON g.nome_jogador = j.nome
WHERE j.nome IS NULL;

-- Goals recorded in the wrong period of the match
SELECT * FROM euro.gols WHERE etapa = N'1º tempo' AND minuto > 45;
SELECT * FROM euro.gols WHERE etapa = N'2º tempo' AND minuto < 46;
SELECT * FROM euro.gols WHERE etapa = N'2º tempo da prorrogação' AND minuto < 106;

-- Goals recorded out of chronological order within the same match.
-- Minutes follow the running clock, so a first-half stoppage-time goal (e.g. 49')
-- has a higher minute than the first goal of the second half (46').
-- Because of that, the period (etapa) must be compared before the minute.
-- Equal minutes are valid (several stoppage-time goals can share a minute).
WITH gols_ordenados AS (
    SELECT idgol, idjogo, etapa, minuto,
           CASE etapa
                WHEN N'1º tempo'                 THEN 1
                WHEN N'2º tempo'                 THEN 2
                WHEN N'1º tempo da prorrogação'  THEN 3
                WHEN N'2º tempo da prorrogação'  THEN 4
           END AS ordem_etapa
    FROM euro.gols
),
comparacao AS (
    SELECT *,
           LAG(ordem_etapa) OVER (PARTITION BY idjogo ORDER BY idgol) AS ordem_anterior,
           LAG(minuto)      OVER (PARTITION BY idjogo ORDER BY idgol) AS minuto_anterior
    FROM gols_ordenados
)
SELECT *
FROM comparacao
WHERE ordem_etapa < ordem_anterior
   OR (ordem_etapa = ordem_anterior AND minuto < minuto_anterior);

-- Number of goals recorded vs. final score (penalty shoot-outs are not counted)
SELECT j.idjogo,
       j.gols_seleção1 + j.gols_seleção2 AS placar_final,
       COUNT(g.idgol) AS gols_registrados
FROM euro.jogos j
LEFT JOIN euro.gols g ON g.idjogo = j.idjogo
GROUP BY j.idjogo, j.gols_seleção1, j.gols_seleção2
HAVING j.gols_seleção1 + j.gols_seleção2 <> COUNT(g.idgol);

-- Impossible running scores
SELECT idgol, idjogo, placar_time, placar_adversario
FROM euro.gols
WHERE placar_time > 10 OR placar_adversario > 10;

-- Inconsistencies in the results table
SELECT * FROM euro.resultados WHERE gols_marcados > gols_sofridos AND VED = 'D';
SELECT * FROM euro.resultados WHERE gols_marcados < gols_sofridos AND VED = 'V';

-- Duplicated names in 'participantes' would duplicate rows in the view
SELECT nome_pais, COUNT(*) AS ocorrencias
FROM euro.participantes
GROUP BY nome_pais
HAVING COUNT(*) > 1;


-------------------------------------------------------
-- Views and auxiliary structures
-------------------------------------------------------

-- View: resultados_atualizados
-- Description:
--   This view consolidates all match results in the database.
--   For each match, it generates two rows - one per team.
--   Includes:
--     * Updated names for each team and opponent
--     * Goals scored and conceded
--     * Contextual information (date, stadium, city, stage, etc.)
--   It uses the 'participantes' table to map old and current country names
--   (e.g., "União Soviética" -> "Rússia").
--
-- Note:
--   This view simplifies aggregations (such as total goals per team)
--   by eliminating the need to differentiate between columns seleção1 and seleção2.

GO
CREATE OR ALTER VIEW resultados_atualizados AS
WITH resultados_duplicados AS (
    -- one row for the first team
    SELECT idjogo, idedicao, fase, [data], horário, país, cidade, estádio,
           seleção1       AS seleção,
           gols_seleção1  AS gols_marcados,
           seleção2       AS adversário,
           gols_seleção2  AS gols_sofridos,
           desempate, venc_desempate
    FROM euro.jogos

    UNION ALL

    -- one row for the second team (perspective inverted)
    SELECT idjogo, idedicao, fase, [data], horário, país, cidade, estádio,
           seleção2       AS seleção,
           gols_seleção2  AS gols_marcados,
           seleção1       AS adversário,
           gols_seleção1  AS gols_sofridos,
           desempate, venc_desempate
    FROM euro.jogos
)
SELECT
    rd.idjogo,
    rd.idedicao,
    rd.fase,
    rd.[data],
    rd.horário,
    rd.país,
    rd.cidade,
    rd.estádio,
    p1.nome_pais_atual AS seleção,
    rd.gols_marcados,
    p2.nome_pais_atual AS adversário,
    rd.gols_sofridos,
    rd.desempate,
    p3.nome_pais_atual AS venc_desempate
FROM resultados_duplicados rd
LEFT JOIN euro.participantes p1 ON rd.seleção = p1.nome_pais
LEFT JOIN euro.participantes p2 ON rd.adversário = p2.nome_pais
LEFT JOIN euro.participantes p3 ON rd.venc_desempate = p3.nome_pais;
GO

-- Sanity check: two rows per match (388 matches -> 776 rows)
SELECT (SELECT COUNT(*) FROM euro.jogos)          AS partidas,
       (SELECT COUNT(*) FROM resultados_atualizados) AS linhas_da_view;

SELECT * FROM resultados_atualizados;


-------------------------------------------------------
-- Auxiliary queries
-------------------------------------------------------

SELECT * FROM euro.edições;


-------------------------------------------------------
-- Example: inserting a record with explicit columns
-- The ROLLBACK keeps the data unchanged.
-------------------------------------------------------

BEGIN TRANSACTION;

INSERT INTO euro.gols
    (idgol, idjogo, idedicao, seleção, nome_jogador, contra, etapa, minuto, placar_time, placar_adversario)
VALUES
    (9999, 388, 17, N'Espanha', N'Mikel Oyarzabal', NULL, N'2º tempo', 86, 2, 1);

SELECT * FROM euro.gols WHERE idgol = 9999;

ROLLBACK;
