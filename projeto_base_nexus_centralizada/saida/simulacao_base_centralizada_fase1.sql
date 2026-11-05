/* =====================================================================
   SIMULAÇÃO DA BASE NEXUS CENTRALIZADA — ESTRUTURA ATUAL (FASE 1)
   ---------------------------------------------------------------------
   SELECT avulso, SÓ LEITURA: não cria nada no banco.
   É o mesmo SELECT da MV_NEXUS_SUPORTE_CENTRAL da fase 1, com a regra
   EXATAMENTE como está hoje nas duas views de produção.

   Período: o mesmo das views atuais (últimos 6 meses, a partir do
   1º dia do mês).

   Como ler o resultado para cada relatório:

   SUPORTE B2C  (= POWERBI_SUPORTE_B2C_NEXUS)
     todas as linhas; colunas sem prefixo DEP_
     (ID_TABULACAO ... REGRA_NEGOCIO_DEPENDENCIA)

   DEPENDÊNCIA DE CAMPO  (= POWERBI_DEPENDENCIA_NEXUS)
     filtro:  FLAG_DEPENDENCIA = 1 AND SEQ_LINHA = 1
     colunas: as de prefixo DEP_ (ex.: DEP_CATEGORIA, DEP_TIPO,
              DEP_FUNCIONALIDADE_MAGIC, DEP_TECNICO, DEP_CLUSTER)
              + ATIVIDADE, ID_TABULACAO, DATA_INICIO, DATA_FIM,
              PRODUTO_ORIGINAL, DEFEITO, PROBLEMA, SOLUCAO, CRM, TIPO_OS

   Exemplos de conferência (envolvendo este SELECT):
     SELECT CATEGORIA, COUNT(*) FROM ( <este select> ) GROUP BY CATEGORIA;
     SELECT DEP_CATEGORIA, COUNT(*) FROM ( <este select> )
      WHERE FLAG_DEPENDENCIA = 1 AND SEQ_LINHA = 1 GROUP BY DEP_CATEGORIA;
   ===================================================================== */
/* =====================================================================
   PARTE 1 — REGRA ATUAL DA POWERBI_SUPORTE_B2C_NEXUS (sem alteração)
   ===================================================================== */
WITH NEXUS_MATCH AS (
    -- Replica a busca/dedup da POWERBI_DEPENDENCIA_NEXUS contra TB_REGRA_MAGIC_NEXUS,
    -- mas usando o mesmo filtro de janela da POWERBI_SUPORTE_B2C_NEXUS (sem os filtros
    -- adicionais SOLUCAO IS NOT NULL / PROBLEMA NOT LIKE '%Queda Ligação%' da dependencia),
    -- para não descartar linhas que existem aqui e não existem lá.
    SELECT *
    FROM (
        SELECT
            B2C.ID_TABULACAO,
            B2C.ATIVIDADE,
            B2C.DATA_INICIO,
            B2C.TIPO AS TIPO_RAW,
            NEXUS.REGRA,

            CASE
                WHEN NEXUS.REGRA = 'Beatrix'
                     AND (B2C.CRM <> 'NEXT' OR B2C.TIPO_OS NOT IN ('Instalação', 'Alteração'))
                THEN 'Sem Funcionalidade'
                ELSE NVL(NEXUS.FUNCIONALIDADE, 'Sem Funcionalidade')
            END AS API,

            -- >>> MANUTENCAO -- DESEMPATE BEATRIX CONDICIONAL (NAO REVERTER) <<<
            -- Mesma correcao aplicada na POWERBI_DEPENDENCIA_NEXUS e na
            -- POWERBI_USABILIDADE_MAGIC_CHAMADOS (diagnostico com o analista,
            -- 2026-07, validado com 20 atividades reais): quando PRODUTO+
            -- DEFEITO+PROBLEMA bate em DUAS regras (uma Beatrix, uma nao-
            -- Beatrix), o desempate antigo sempre preferia Beatrix mesmo
            -- quando a atividade nao era elegivel (CRM<>NEXT ou TIPO_OS fora
            -- de Instalacao/Alteracao) -- o filtro de elegibilidade so
            -- reprova DEPOIS do desempate, entao o resultado virava "Sem
            -- Funcionalidade" em vez de cair na regra nao-Beatrix valida.
            ROW_NUMBER() OVER (
                PARTITION BY B2C.ID_TABULACAO
                ORDER BY
                    CASE WHEN NEXUS.FUNCIONALIDADE IS NOT NULL THEN 1 ELSE 2 END,
                    CASE
                        WHEN B2C.CRM = 'NEXT' AND B2C.TIPO_OS IN ('Instalação', 'Alteração') THEN
                            CASE WHEN NEXUS.REGRA = 'Beatrix' THEN 1 ELSE 2 END
                        ELSE
                            CASE WHEN NEXUS.REGRA = 'Beatrix' THEN 2 ELSE 1 END
                    END,
                    NEXUS.FUNCIONALIDADE,
                    NEXUS.REGRA
            ) AS RN

        FROM
            PORTALINTEGRA_TABULADOR_B2C B2C

        LEFT JOIN TB_REGRA_MAGIC_NEXUS NEXUS
            ON B2C.PRODUTO = NEXUS.PRODUTO
           AND B2C.DEFEITO = NEXUS.DEFEITO_RECLAMADO
           AND B2C.PROBLEMA = NEXUS.PROBLEMA_ENCONTRADO

        WHERE
            B2C.DATA_INICIO >= TRUNC(ADD_MONTHS(SYSDATE, -6), 'MM')
            AND B2C.DATA_INICIO >= TO_DATE('01-10-2025', 'DD/MM/YYYY')
            AND B2C.VALIDADO = 1
    )
    WHERE RN = 1
),

MAGIC_DEDUP AS (
    /*
       Primeira execução de cada família do MagicTool por atividade.
       A agregação por família preserva a cardinalidade quando carga-psa
       e checklist-vlan aparecem na mesma atividade.
    */
    SELECT
        ACTIVITY_ID,
        CASE
            WHEN TRIM(LOWER(FUNCIONALIDADE)) IN ('carga-psa', 'checklist-vlan')
            THEN 'config-rede'
            ELSE TRIM(LOWER(FUNCIONALIDADE))
        END AS FAMILIA,
        MIN(DT_INICIO - INTERVAL '3' HOUR) AS DT_INICIO_MAGIC
    FROM B2C_SUPORTE_MAGIC_M
    GROUP BY
        ACTIVITY_ID,
        CASE
            WHEN TRIM(LOWER(FUNCIONALIDADE)) IN ('carga-psa', 'checklist-vlan')
            THEN 'config-rede'
            ELSE TRIM(LOWER(FUNCIONALIDADE))
        END
),

MAGIC_ANY AS (
    /* Indica qualquer utilização do MagicTool na atividade. */
    SELECT DISTINCT
        ACTIVITY_ID
    FROM B2C_SUPORTE_MAGIC_M
),

BASE_MAGIC AS (
    SELECT
        NX.ID_TABULACAO,
        NX.API,

        CASE
            WHEN TRIM(LOWER(NX.API)) IN ('checklist-vlan', 'carga-psa')
            THEN 'Configuração de Rede'
            WHEN TRIM(LOWER(NX.API)) = 'iptv' THEN 'Reenvio Pacotes'
            WHEN TRIM(LOWER(NX.API)) = 'manobra' THEN 'Manobra'
            WHEN TRIM(LOWER(NX.API)) = 'fxs' THEN 'Reenvio FXS'
            ELSE NX.API
        END AS FUNCIONALIDADE,

        CASE
            WHEN NX.REGRA = 'Beatrix'
                 AND NX.API = 'Sem Funcionalidade'
            THEN 'DEVIDO'
            ELSE NX.TIPO_RAW
        END AS TIPO_ORIGINAL,

        MAGIC_EXATO.DT_INICIO_MAGIC,

        CASE
            WHEN NX.API = 'Sem Funcionalidade'
            THEN '-'

            WHEN MAGIC_EXATO.ACTIVITY_ID IS NOT NULL
                 AND NX.DATA_INICIO >= MAGIC_EXATO.DT_INICIO_MAGIC
            THEN 'Sim'

            WHEN MAGIC_EXATO.ACTIVITY_ID IS NOT NULL
                 AND NX.DATA_INICIO < MAGIC_EXATO.DT_INICIO_MAGIC
            THEN 'Utilizado Depois'

            WHEN MAGIC_QQ.ACTIVITY_ID IS NOT NULL
            THEN 'Uso Incorreto'

            ELSE 'Não'
        END AS USO_API_CORRETA

    FROM NEXUS_MATCH NX

    LEFT JOIN MAGIC_DEDUP MAGIC_EXATO
        ON NX.ATIVIDADE = MAGIC_EXATO.ACTIVITY_ID
       AND CASE
               WHEN TRIM(LOWER(NX.API)) IN ('carga-psa', 'checklist-vlan')
               THEN 'config-rede'
               ELSE TRIM(LOWER(NX.API))
           END = MAGIC_EXATO.FAMILIA

    LEFT JOIN MAGIC_ANY MAGIC_QQ
        ON NX.ATIVIDADE = MAGIC_QQ.ACTIVITY_ID
),

BASE_DEPENDENCIA AS (
    SELECT
        BM.ID_TABULACAO,
        BM.API,
        BM.FUNCIONALIDADE,
        BM.TIPO_ORIGINAL,
        BM.DT_INICIO_MAGIC,
        BM.USO_API_CORRETA,

        CASE
            WHEN BM.TIPO_ORIGINAL IS NOT NULL
                 AND BM.USO_API_CORRETA = 'Sim'
            THEN 'DEVIDO'

            WHEN BM.TIPO_ORIGINAL IS NOT NULL
                 AND BM.USO_API_CORRETA IN (
                     'Não',
                     'Uso Incorreto',
                     'Utilizado Depois'
                 )
            THEN 'INDEVIDO'

            ELSE BM.TIPO_ORIGINAL
        END AS TIPO_DEPENDENCIA

    FROM BASE_MAGIC BM
),

/* =====================================================================
   PARTE 2 — REGRA ATUAL DA POWERBI_DEPENDENCIA_NEXUS (sem alteração;
   blocos renomeados com DEP_ para não colidir com a parte 1)
   ===================================================================== */
DEP_CONSULTA_BASE AS (
    SELECT *
    FROM (
        SELECT
            B2C.ATIVIDADE,
            B2C.ID_TABULACAO,
            B2C.DATA_INICIO,
            B2C.DATA_FIM,
            B2C.PRODUTO,
            B2C.DEFEITO,
            B2C.PROBLEMA,
            B2C.SOLUCAO,
            B2C.TIPO,
            B2C.CRM,
            B2C.TIPO_OS,
            NEXUS.REGRA,

            CASE
                WHEN NEXUS.REGRA = 'Beatrix'
                     AND (
                         B2C.CRM <> 'NEXT'
                         OR B2C.TIPO_OS NOT IN ('Instalação', 'Alteração')
                     )
                THEN 'Sem Funcionalidade'
                ELSE NVL(NEXUS.FUNCIONALIDADE, 'Sem Funcionalidade')
            END AS API,

            ROW_NUMBER() OVER (
                PARTITION BY B2C.ID_TABULACAO
                ORDER BY
                    CASE WHEN NEXUS.FUNCIONALIDADE IS NOT NULL THEN 1 ELSE 2 END,
                    CASE WHEN NEXUS.REGRA = 'Beatrix' THEN 1 ELSE 2 END,
                    NEXUS.FUNCIONALIDADE,
                    NEXUS.REGRA
            ) AS RN

        FROM PORTALINTEGRA_TABULADOR_B2C B2C

        LEFT JOIN TB_REGRA_MAGIC_NEXUS NEXUS
            ON B2C.PRODUTO = NEXUS.PRODUTO
           AND B2C.DEFEITO = NEXUS.DEFEITO_RECLAMADO
           AND B2C.PROBLEMA = NEXUS.PROBLEMA_ENCONTRADO

        WHERE
            B2C.DATA_INICIO >= TRUNC(ADD_MONTHS(SYSDATE, -6), 'MM')
            AND B2C.DATA_INICIO >= DATE '2025-10-01'
            AND B2C.VALIDADO = 1
            AND B2C.SOLUCAO IS NOT NULL
            AND B2C.PROBLEMA NOT IN(
                                'Queda de ligação',
                                'Atendente não concluiu registro',
                                'Queda Ligação Durante Atendimento'
                                )
    )
    WHERE RN = 1
),

/* Menor data da funcionalidade utilizada na atividade */
DEP_MAGIC_DEDUP AS (
    SELECT
        ACTIVITY_ID,
        FUNCIONALIDADE,
        MIN(DT_INICIO - INTERVAL '3' HOUR) AS DT_INICIO
    FROM B2C_SUPORTE_MAGIC_M
    GROUP BY
        ACTIVITY_ID,
        FUNCIONALIDADE
),

/* Utilizado apenas para validar se a atividade existe */
DEP_MAGIC_ATIVIDADE AS (
    SELECT DISTINCT
        ACTIVITY_ID
    FROM B2C_SUPORTE_MAGIC_M
),

/* Deduplicação da BI_ETA_DIRECT para evitar duplicidade */
DEP_ETA_DIRECT AS (
    SELECT
        GA_AID,
        GA_EXTERNAL_ID,
        GA_PNAME,
        GA_XR_COMPANY_NAME,
        GA_XA_CNL,
        GA_XA_AT
    FROM (
        SELECT
            GA_AID,
            GA_EXTERNAL_ID,
            GA_PNAME,
            GA_XR_COMPANY_NAME,
            GA_XA_CNL,
            GA_XA_AT,
            ROW_NUMBER() OVER (
                PARTITION BY GA_AID
                ORDER BY GA_AID
            ) RN
        FROM BI_ETA_DIRECT
    )
    WHERE RN = 1
),

/* Deduplicação da ANALYT_REGIONAIS para evitar duplicidade */
DEP_REGIONAIS AS (
    SELECT
        CNL_AT,
        REGIONAIS,
        CLUSTER_COM_ACENTUACAO,
        REGIONAIS_SIGLA,
        UF_SIGLA,
        ESTADOS_COM_ACENTUACAO,
        CIDADES_COM_ACENTUACAO,
        CLUSTER_LATITUDE,
        CLUSTER_LONGITUDE
    FROM (
        SELECT
            CNL_AT,
            REGIONAIS,
            CLUSTER_COM_ACENTUACAO,
            REGIONAIS_SIGLA,
            UF_SIGLA,
            ESTADOS_COM_ACENTUACAO,
            CIDADES_COM_ACENTUACAO,
            CLUSTER_LATITUDE,
            CLUSTER_LONGITUDE,
            ROW_NUMBER() OVER (
                PARTITION BY CNL_AT
                ORDER BY CNL_AT
            ) RN
        FROM ANALYT_REGIONAIS
    )
    WHERE RN = 1
),

DEP_CONSULTA_INTERMEDIARIA AS (
    SELECT
        BASE.ATIVIDADE,
        BASE.ID_TABULACAO,
        BASE.DATA_INICIO,
        BASE.DATA_FIM,
        MAGIC.DT_INICIO AS DT_INICIO_MAGIC,
        BASE.PRODUTO,
        BASE.DEFEITO,
        BASE.PROBLEMA,
        BASE.SOLUCAO,
        LOWER(BASE.API) AS API,
        BASE.CRM,
        BASE.TIPO_OS,

        CASE
            WHEN LOWER(BASE.API) = 'checklist-vlan' THEN 'Configuração de Rede'
            WHEN LOWER(BASE.API) = 'carga-psa' THEN 'Configuração de Rede'
            WHEN LOWER(BASE.API) = 'iptv' THEN 'Reenvio Pacotes'
            WHEN LOWER(BASE.API) = 'manobra' THEN 'Manobra'
            WHEN LOWER(BASE.API) = 'fxs' THEN 'Reenvio FXS'
            ELSE BASE.API
        END AS FUNCIONALIDADE,

        CASE
            WHEN BASE.REGRA = 'Beatrix'
                 AND BASE.API = 'Sem Funcionalidade'
            THEN 'DEVIDO'
            ELSE BASE.TIPO
        END AS TIPO_ORIGINAL,

        CASE
            WHEN BASE.API = 'Sem Funcionalidade'
            THEN '-'

            WHEN MAGIC.ACTIVITY_ID IS NOT NULL
                 AND BASE.DATA_INICIO >= MAGIC.DT_INICIO
            THEN 'Sim'

            WHEN MAGIC.ACTIVITY_ID IS NOT NULL
                 AND BASE.DATA_INICIO < MAGIC.DT_INICIO
            THEN 'Utilizado Depois'

            WHEN MAGIC_ATIV.ACTIVITY_ID IS NOT NULL
            THEN 'Uso Incorreto'

            ELSE 'Não'
        END AS FUNCIONALIDADE_MAGIC

    FROM DEP_CONSULTA_BASE BASE

    LEFT JOIN DEP_MAGIC_DEDUP MAGIC
        ON BASE.ATIVIDADE = MAGIC.ACTIVITY_ID
       AND LOWER(BASE.API) = MAGIC.FUNCIONALIDADE

    LEFT JOIN DEP_MAGIC_ATIVIDADE MAGIC_ATIV
        ON BASE.ATIVIDADE = MAGIC_ATIV.ACTIVITY_ID
),

DEP_SAIDA AS (
SELECT
    INT.ATIVIDADE,
    INT.ID_TABULACAO,
    INT.DATA_INICIO,
    INT.DATA_FIM,
    INT.DT_INICIO_MAGIC,
    INT.PRODUTO,
    INT.DEFEITO,
    INT.PROBLEMA,
    INT.SOLUCAO,
    INT.API,
    INT.FUNCIONALIDADE,
    INT.FUNCIONALIDADE_MAGIC,
    INT.CRM,
    INT.TIPO_OS,

    ETA.GA_EXTERNAL_ID      AS MATRICULA,
    ETA.GA_PNAME            AS TECNICO,
    ETA.GA_XR_COMPANY_NAME  AS CONTRATO,
    ETA.GA_XA_CNL           AS CNL,
    ETA.GA_XA_AT            AS AT_,

    REG.REGIONAIS              AS REGIONAL,
    REG.CLUSTER_COM_ACENTUACAO AS CLUSTER_,
    REG.REGIONAIS_SIGLA        AS REGIONAL_ACRONIMO,
    REG.UF_SIGLA               AS UF_,
    REG.ESTADOS_COM_ACENTUACAO AS ESTADO,
    REG.CIDADES_COM_ACENTUACAO AS CIDADE,
    REG.CLUSTER_LATITUDE,
    REG.CLUSTER_LONGITUDE,

    CASE
        WHEN INT.TIPO_ORIGINAL IS NOT NULL
             AND INT.FUNCIONALIDADE_MAGIC = 'Sim'
        THEN 'DEVIDO'

        WHEN INT.TIPO_ORIGINAL IS NOT NULL
             AND INT.FUNCIONALIDADE_MAGIC IN (
                 'Não',
                 'Uso Incorreto',
                 'Utilizado Depois'
             )
        THEN 'INDEVIDO'

        ELSE INT.TIPO_ORIGINAL
    END AS TIPO,

    CASE
        WHEN INT.FUNCIONALIDADE_MAGIC IN(
                'Não',
                'Uso Incorreto',
                'Utilizado Depois'
            )
        THEN 'Indevido Uso MagicTool'

        WHEN (
            CASE
                WHEN INT.TIPO_ORIGINAL IS NOT NULL
                     AND INT.FUNCIONALIDADE_MAGIC = 'Sim'
                THEN 'DEVIDO'

                WHEN INT.TIPO_ORIGINAL IS NOT NULL
                     AND INT.FUNCIONALIDADE_MAGIC IN (
                         'Não',
                         'Uso Incorreto',
                         'Utilizado Depois'
                     )
                THEN 'INDEVIDO'

                ELSE INT.TIPO_ORIGINAL
            END
        ) = 'INDEVIDO'
        THEN 'Indevido Processos Campo'

        WHEN (
            CASE
                WHEN INT.TIPO_ORIGINAL IS NOT NULL
                     AND INT.FUNCIONALIDADE_MAGIC = 'Sim'
                THEN 'DEVIDO'

                WHEN INT.TIPO_ORIGINAL IS NOT NULL
                     AND INT.FUNCIONALIDADE_MAGIC IN (
                         'Não',
                         'Uso Incorreto',
                         'Utilizado Depois'
                     )
                THEN 'INDEVIDO'

                ELSE INT.TIPO_ORIGINAL
            END
        ) = 'DEVIDO'
        THEN 'Devido Suporte'

        WHEN INT.TIPO_ORIGINAL IS NULL
        THEN NULL
    END AS CATEGORIA,
    CASE
        WHEN INT.FUNCIONALIDADE_MAGIC = 'Não'
        THEN 'MagicTool - Nenhuma API Executada'

        WHEN INT.FUNCIONALIDADE_MAGIC = 'Uso Incorreto'
        THEN 'API Incorreta - ' || INT.API || ' Não Executada'

        WHEN INT.FUNCIONALIDADE_MAGIC = 'Utilizado Depois'
        THEN 'API ' || INT.API || ' Executada Após Atendimento'

        ELSE INT.SOLUCAO
    END AS CATEGORIA_DETALHE

FROM DEP_CONSULTA_INTERMEDIARIA INT

LEFT JOIN DEP_ETA_DIRECT ETA
    ON INT.ATIVIDADE = ETA.GA_AID

LEFT JOIN DEP_REGIONAIS REG
    ON REG.CNL_AT =
           CASE
               WHEN ETA.GA_XA_CNL LIKE '1%'
                    AND ETA.GA_XA_CNL || ETA.GA_XA_AT <> '11041'
               THEN ETA.GA_XA_CNL || '_' || ETA.GA_XA_AT
               ELSE ETA.GA_XA_CNL
           END

)

/* =====================================================================
   SAÍDA — colunas da POWERBI_SUPORTE_B2C_NEXUS + acréscimos da base
   ===================================================================== */
SELECT
    B2C.ID_TABULACAO,
    B2C.MATRICULA_OPERADOR,
    B2C.DATA_INICIO,
    B2C.DATA_FIM,
    B2C.CHAMADO,
    B2C.TIPO_TROCA,
    B2C.ID_GPS,
    B2C.ATIVIDADE,
    B2C.ID_CADASTRO,
    B2C.PON,
    B2C.OLT,
    B2C.REDE,
    B2C.CRM,
    B2C.SLID,
    B2C.SLOT,
    B2C.PORTA,
    B2C.CABO,
    B2C.PRIMARIA,
    B2C.BANDA_DESIGNADOR,
    B2C.BANDA_IP_FIXO,
    B2C.TV_DESIGNADOR,
    B2C.TV_PACOTE,
    B2C.VOZ_DESIGNADOR,
    B2C.SPLITTER,
    B2C.AREA_TELEFONICA,
    B2C.CNL,
    B2C.DESIGNADOR_ACESSO,
    B2C.INSTANCIAS,
    B2C.AREA_GEOGRAFICA,
    B2C.AREA_BLACKOUT,
    B2C.TV_DISPOSITIVOS,
    B2C.ID,
    B2C.CLIENTE_ANATEL,
    B2C.STATUS_MAX,
    CASE
        WHEN LENGTH(TRIM(B2C.INSTANCIAS)) > 10
             AND B2C.PRODUTO = 'Voz'
        THEN 'ATA'
        ELSE B2C.PRODUTO
    END AS PRODUTO,
    B2C.DEFEITO,
    B2C.PROBLEMA,
    B2C.SOLUCAO,
    INITCAP(
        CASE
            WHEN B2C.DATA_INICIO < TO_DATE('12/11/2025', 'DD/MM/YYYY') THEN NULL
            WHEN B2C.TIPO IS NULL THEN 'INDEFINIDO'
            WHEN B2C.SOLUCAO IN ('Queda de Ligação', 'Queda Ligação') THEN 'IMPRODUTIVO'
            ELSE B2C.TIPO
        END
    ) AS TIPO,
    CASE
        WHEN B2C.DATA_FIM = MAX(B2C.DATA_FIM) OVER (PARTITION BY B2C.ATIVIDADE)
        THEN 'Resolvido'
        ELSE 'Rechamou'
    END AS RESOLUCAO,
    -- Colunas adicionais da tabela COLABORADORES
    CASE
        WHEN CLB.AREA_ATUACAO = 'SUPORTE TEL' THEN 'TEL'
        WHEN CLB.CIDADE = 'SAO PAULO' THEN 'SPO'
        WHEN CLB.CIDADE = 'CURITIBA' THEN 'CTA'
        ELSE CLB.CIDADE
    END AS CO,

    INITCAP(CLB.COLABORADOR) AS COLABORADOR,

    INITCAP(
      TRIM(
        CASE
          WHEN CLB.SUPERIOR_IMEDIATO LIKE '% CO'
            THEN SUBSTR(CLB.SUPERIOR_IMEDIATO, 1, LENGTH(CLB.SUPERIOR_IMEDIATO) - 3)
          ELSE CLB.SUPERIOR_IMEDIATO
        END
      )
    ) AS SUPERIOR_IMEDIATO,

    INITCAP(
      TRIM(
        CASE
          WHEN CLB.COORDENACAO LIKE '% CO'
            THEN SUBSTR(CLB.COORDENACAO, 1, LENGTH(CLB.COORDENACAO) - 3)
          ELSE CLB.COORDENACAO
        END
      )
    ) AS COORDENACAO,

    INITCAP(
      TRIM(
        CASE
          WHEN CLB.GERENCIA LIKE '% CO'
            THEN SUBSTR(CLB.GERENCIA, 1, LENGTH(CLB.GERENCIA) - 3)
          ELSE CLB.GERENCIA
        END
      )
    ) AS GERENCIA,

    CLB.AREA_ATUACAO,
    CLB.TIPO_DE_CARGO,
    CLB.TIPO_OPERACAO,
    LOWER(CLB.EMAIL) AS EMAIL,
    -- Colunas adicionais da tabela LOCALIDADE
    LOC.REGIONAL,
    LOC.CLUSTER_,
    LOC.UF_,
    LOC.CIDADE,
    LOC.LOCALIDADE_DETAIL,
    LOC.AT_NOME,

    -- Colunas da regra completa de dependência e uso do MagicTool
    DEP.API,
    DEP.FUNCIONALIDADE,
    DEP.DT_INICIO_MAGIC,
    DEP.USO_API_CORRETA,
    DEP.TIPO_DEPENDENCIA,

    CASE
        WHEN DEP.USO_API_CORRETA IN (
            'Não',
            'Uso Incorreto',
            'Utilizado Depois'
        )
        THEN 'Indevido Uso MagicTool'

        WHEN DEP.TIPO_DEPENDENCIA = 'INDEVIDO'
        THEN 'Indevido Processos Campo'

        WHEN DEP.TIPO_DEPENDENCIA = 'DEVIDO'
        THEN 'Devido Suporte'

        WHEN DEP.TIPO_ORIGINAL IS NULL
        THEN NULL
    END AS CATEGORIA,

    CASE
        WHEN DEP.USO_API_CORRETA = 'Não'
        THEN 'MagicTool - Nenhuma API Executada'

        WHEN DEP.USO_API_CORRETA = 'Uso Incorreto'
        THEN 'API Incorreta - ' || DEP.API || ' Não Executada'

        WHEN DEP.USO_API_CORRETA = 'Utilizado Depois'
        THEN 'API ' || DEP.API || ' Executada Após Atendimento'

        ELSE B2C.SOLUCAO
    END AS CATEGORIA_DETALHE,

    -- Flag do universo da view de dependência, sem remover linhas desta view.
    CASE
        WHEN B2C.SOLUCAO IS NOT NULL
             AND B2C.PROBLEMA NOT IN (
                 'Queda de ligação',
                 'Atendente não concluiu registro',
                 'Queda Ligação Durante Atendimento'
             )
        THEN 1
        ELSE 0
    END AS REGRA_NEGOCIO_DEPENDENCIA,

    /* =================================================================
       ACRÉSCIMOS DA BASE CENTRAL (não alteram nenhuma coluna acima)
       ================================================================= */
    -- campos do tabulador mantidos como a operação preencheu
    B2C.PRODUTO          AS PRODUTO_ORIGINAL,
    B2C.TIPO_OS,
    B2C.TIPO             AS TIPO_OPERADOR,
    B2C.OBSERVACAO,
    B2C.STATUS,
    B2C.VALIDADO,
    B2C.MAGIC,
    B2C.MAGIC_UTILIZADO,
    B2C.TECNICO_MATRICULA,
    B2C.TECNICO_NOME,
    B2C.TECNICO_EMPRESA,
    B2C.CIDADE           AS CIDADE_TABULADOR,
    B2C.ESTADO           AS ESTADO_TABULADOR,

    -- controle: linha pertence ao relatório de Dependência / ordem da linha
    -- quando a tabulação se repete (cadastro duplicado de colaborador ou
    -- localidade, como acontece hoje na view atual)
    CASE WHEN DS.ID_TABULACAO IS NOT NULL THEN 1 ELSE 0 END AS FLAG_DEPENDENCIA,
    ROW_NUMBER() OVER (
        PARTITION BY B2C.ID_TABULACAO
        ORDER BY CLB.ID_COLAB, LOC.CNL_AT
    ) AS SEQ_LINHA,

    -- colunas calculadas pela regra atual da POWERBI_DEPENDENCIA_NEXUS
    DS.DT_INICIO_MAGIC       AS DEP_DT_INICIO_MAGIC,
    DS.API                   AS DEP_API,
    DS.FUNCIONALIDADE        AS DEP_FUNCIONALIDADE,
    DS.FUNCIONALIDADE_MAGIC  AS DEP_FUNCIONALIDADE_MAGIC,
    DS.MATRICULA             AS DEP_MATRICULA,
    DS.TECNICO               AS DEP_TECNICO,
    DS.CONTRATO              AS DEP_CONTRATO,
    DS.CNL                   AS DEP_CNL,
    DS.AT_                   AS DEP_AT,
    DS.REGIONAL              AS DEP_REGIONAL,
    DS.CLUSTER_              AS DEP_CLUSTER,
    DS.REGIONAL_ACRONIMO     AS DEP_REGIONAL_ACRONIMO,
    DS.UF_                   AS DEP_UF,
    DS.ESTADO                AS DEP_ESTADO,
    DS.CIDADE                AS DEP_CIDADE,
    DS.CLUSTER_LATITUDE      AS DEP_CLUSTER_LATITUDE,
    DS.CLUSTER_LONGITUDE     AS DEP_CLUSTER_LONGITUDE,
    DS.TIPO                  AS DEP_TIPO,
    DS.CATEGORIA             AS DEP_CATEGORIA,
    DS.CATEGORIA_DETALHE     AS DEP_CATEGORIA_DETALHE,

    SYSDATE                  AS DT_ATUALIZACAO_BASE

FROM
    PORTALINTEGRA_TABULADOR_B2C B2C
LEFT JOIN
    ANALYT_COLABORADORES_HIST CLB
    ON (B2C.MATRICULA_OPERADOR || TO_CHAR(B2C.DATA_INICIO, 'YYYYMM')) =
       (CLB.MATRICULA_ANTIGA   || CLB.ANOMES)
LEFT JOIN
    DE_PARA_LOCALIDADE LOC
    ON TRIM(LOC.CNL_AT) = CASE
                       WHEN SUBSTR(B2C.CNL, 1, 1) = '1'
                       THEN B2C.CNL || '_' || B2C.AREA_TELEFONICA
                       ELSE B2C.CNL
                    END
LEFT JOIN
    BASE_DEPENDENCIA DEP
    ON DEP.ID_TABULACAO = B2C.ID_TABULACAO
LEFT JOIN
    DEP_SAIDA DS
    ON DS.ID_TABULACAO = B2C.ID_TABULACAO
WHERE
    B2C.DATA_INICIO >= TRUNC(ADD_MONTHS(SYSDATE, -6), 'MM')
    AND B2C.DATA_INICIO >= TO_DATE('01-10-2025', 'DD/MM/YYYY')
    AND B2C.VALIDADO = 1
