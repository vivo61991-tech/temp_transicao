/* =====================================================================
   SIMULAÇÃO DA BASE NEXUS CENTRALIZADA
   ---------------------------------------------------------------------
   SELECT avulso, SÓ LEITURA: não cria nada no banco.

   Estrutura e regra: POWERBI_DEPENDENCIA_NEXUS - view proposta
   (Magic com a regra dos 10 minutos, técnico pelo BI_ETA_DIRECT e
   localidade pela ANALYT_REGIONAIS), sem alteração na regra.

   Acréscimos para atender todos os relatórios:
   - TODAS as linhas do Nexus no período (uma por ID_TABULACAO);
     a Dependência aplica na view dela:
        SOLUCAO IS NOT NULL
        AND PROBLEMA NOT IN ('Queda de ligação',
                             'Atendente não concluiu registro',
                             'Queda Ligação Durante Atendimento')
   - Demais campos do PORTALINTEGRA_TABULADOR_B2C. Os que têm o mesmo
     nome de uma coluna da Dependência foram renomeados:
        CNL -> NEXUS_CNL, CIDADE -> NEXUS_CIDADE, ESTADO -> NEXUS_ESTADO,
        TIPO (da operação) -> TIPO_OPERADOR
   - RESOLUCAO (Resolvido / Rechamou)
   - Colaborador (ANALYT_COLABORADORES_HIST), como no relatório do Suporte

   Colunas da Dependência (mesmos nomes da view proposta):
   ATIVIDADE, ID_TABULACAO, DATA_INICIO, DATA_FIM, DT_INICIO_MAGIC,
   PRODUTO, DEFEITO, PROBLEMA, SOLUCAO, API, FUNCIONALIDADE,
   FUNCIONALIDADE_MAGIC, CRM, TIPO_OS, MATRICULA, TECNICO, CONTRATO,
   CNL, AT, REGIONAL, CLUSTER_, REGIONAL_ACRONIMO, UF_, ESTADO, CIDADE,
   CLUSTER_LATITUDE, CLUSTER_LONGITUDE, TIPO, CATEGORIA, CATEGORIA_DETALHE
   ===================================================================== */
WITH CONSULTA_BASE AS (
    SELECT *
    FROM (
        SELECT
            B2C.*,
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
    )
    WHERE RN = 1
),

/* Menor data da funcionalidade utilizada na atividade */
MAGIC_DEDUP AS (
    SELECT
        ACTIVITY_ID,
        FUNCIONALIDADE,
        DT_INICIO - INTERVAL '3' HOUR AS DT_INICIO,
        DT_FIM    - INTERVAL '3' HOUR AS DT_FIM
    FROM (
        SELECT
            ACTIVITY_ID,
            FUNCIONALIDADE,
            DT_INICIO,
            DT_FIM,
            ROW_NUMBER() OVER (
                PARTITION BY ACTIVITY_ID, FUNCIONALIDADE
                ORDER BY DT_INICIO
            ) RN
        FROM B2C_SUPORTE_MAGIC_M
    )
    WHERE RN = 1
),

/* Utilizado apenas para validar se a atividade existe */
MAGIC_ATIVIDADE AS (
    SELECT DISTINCT
        ACTIVITY_ID
    FROM B2C_SUPORTE_MAGIC_M
),

/* Deduplicação da BI_ETA_DIRECT para evitar duplicidade */
ETA_DIRECT AS (
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
REGIONAIS AS (
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

/* Colaborador (operador): uma linha por matrícula e mês */
COLABORADOR AS (
    SELECT *
    FROM (
        SELECT
            C.*,
            ROW_NUMBER() OVER (
                PARTITION BY C.MATRICULA_ANTIGA, C.ANOMES
                ORDER BY
                    CASE WHEN C.STATUS_ATUAL = 'EM PRODUCAO' THEN 1 ELSE 2 END,
                    C.ID_COLAB DESC
            ) RN
        FROM ANALYT_COLABORADORES_HIST C
    )
    WHERE RN = 1
),

CONSULTA_INTERMEDIARIA AS (
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
                 AND MAGIC.DT_FIM < BASE.DATA_INICIO
            THEN 'Sim'
        
            WHEN MAGIC.ACTIVITY_ID IS NOT NULL
                 AND BASE.DATA_INICIO >= MAGIC.DT_INICIO
                 AND BASE.DATA_INICIO < MAGIC.DT_INICIO + INTERVAL '10' MINUTE
            THEN 'Não aguardou tempo minimo'
        
            WHEN MAGIC.ACTIVITY_ID IS NOT NULL
                 AND BASE.DATA_INICIO >= MAGIC.DT_INICIO + INTERVAL '10' MINUTE
            THEN 'Sim'
        
            WHEN MAGIC.ACTIVITY_ID IS NOT NULL
                 AND BASE.DATA_INICIO < MAGIC.DT_INICIO
            THEN 'Utilizado Depois'
        
            WHEN MAGIC_ATIV.ACTIVITY_ID IS NOT NULL
            THEN 'Uso Incorreto'
        
            ELSE 'Não'
        END AS FUNCIONALIDADE_MAGIC

    FROM CONSULTA_BASE BASE

    LEFT JOIN MAGIC_DEDUP MAGIC
        ON BASE.ATIVIDADE = MAGIC.ACTIVITY_ID
       AND LOWER(BASE.API) = MAGIC.FUNCIONALIDADE

    LEFT JOIN MAGIC_ATIVIDADE MAGIC_ATIV
        ON BASE.ATIVIDADE = MAGIC_ATIV.ACTIVITY_ID
)

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
    ETA.GA_XA_AT            AS AT,

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

        WHEN INT.FUNCIONALIDADE_MAGIC = 'Não Aguardou Tempo Mínimo' 
        THEN 'API ' || INT.API || ' Não Aguardou Tempo de Execução'
   
        ELSE INT.SOLUCAO
    END AS CATEGORIA_DETALHE,

    /* =================================================================
       DEMAIS CAMPOS DO NEXUS (PORTALINTEGRA_TABULADOR_B2C)
       ================================================================= */
    NX.MATRICULA_OPERADOR,
    NX.CHAMADO,
    NX.TIPO_TROCA,
    NX.ID_GPS,
    NX.OBSERVACAO,
    NX.PON,
    NX.OLT,
    NX.REDE,
    NX.SLID,
    NX.SLOT,
    NX.PORTA,
    NX.CABO,
    NX.PRIMARIA,
    NX.BANDA_DESIGNADOR,
    NX.BANDA_IP_FIXO,
    NX.TV_DESIGNADOR,
    NX.TV_PACOTE,
    NX.VOZ_DESIGNADOR,
    NX.SPLITTER,
    NX.AREA_TELEFONICA,
    NX.CNL                      AS NEXUS_CNL,
    NX.DESIGNADOR_ACESSO,
    NX.INSTANCIAS,
    NX.AREA_GEOGRAFICA,
    NX.AREA_BLACKOUT,
    NX.TV_DISPOSITIVOS,
    NX.ID,
    NX.CLIENTE_ANATEL,
    NX.STATUS_MAX,
    NX.STATUS,
    NX.VALIDADO,
    NX.ID_CADASTRO,
    NX.TIPO                     AS TIPO_OPERADOR,
    NX.MAGIC,
    NX.TECNICO_MATRICULA,
    NX.TECNICO_NOME,
    NX.TECNICO_EMPRESA,
    NX.CIDADE                   AS NEXUS_CIDADE,
    NX.ESTADO                   AS NEXUS_ESTADO,
    NX.MAGIC_UTILIZADO,
    CASE
        WHEN NX.DATA_FIM = MAX(NX.DATA_FIM) OVER (PARTITION BY NX.ATIVIDADE)
        THEN 'Resolvido'
        ELSE 'Rechamou'
    END AS RESOLUCAO,

    /* =================================================================
       COLABORADOR (operador) — ANALYT_COLABORADORES_HIST
       ================================================================= */
    CASE
        WHEN CLB.AREA_ATUACAO = 'SUPORTE TEL' THEN 'TEL'
        WHEN CLB.CIDADE = 'SAO PAULO' THEN 'SPO'
        WHEN CLB.CIDADE = 'CURITIBA' THEN 'CTA'
        ELSE CLB.CIDADE
    END AS CO,
    INITCAP(CLB.COLABORADOR) AS COLABORADOR,
    INITCAP(TRIM(CASE WHEN CLB.SUPERIOR_IMEDIATO LIKE '% CO'
                      THEN SUBSTR(CLB.SUPERIOR_IMEDIATO, 1, LENGTH(CLB.SUPERIOR_IMEDIATO) - 3)
                      ELSE CLB.SUPERIOR_IMEDIATO END)) AS SUPERIOR_IMEDIATO,
    INITCAP(TRIM(CASE WHEN CLB.COORDENACAO LIKE '% CO'
                      THEN SUBSTR(CLB.COORDENACAO, 1, LENGTH(CLB.COORDENACAO) - 3)
                      ELSE CLB.COORDENACAO END)) AS COORDENACAO,
    INITCAP(TRIM(CASE WHEN CLB.GERENCIA LIKE '% CO'
                      THEN SUBSTR(CLB.GERENCIA, 1, LENGTH(CLB.GERENCIA) - 3)
                      ELSE CLB.GERENCIA END)) AS GERENCIA,
    CLB.AREA_ATUACAO,
    CLB.TIPO_DE_CARGO,
    CLB.TIPO_OPERACAO,
    LOWER(CLB.EMAIL) AS EMAIL

FROM CONSULTA_INTERMEDIARIA INT

LEFT JOIN CONSULTA_BASE NX
    ON NX.ID_TABULACAO = INT.ID_TABULACAO

LEFT JOIN COLABORADOR CLB
    ON CLB.MATRICULA_ANTIGA = NX.MATRICULA_OPERADOR
   AND TO_CHAR(CLB.ANOMES) = TO_CHAR(NX.DATA_INICIO, 'YYYYMM')

LEFT JOIN ETA_DIRECT ETA
    ON INT.ATIVIDADE = ETA.GA_AID

LEFT JOIN REGIONAIS REG
    ON REG.CNL_AT =
           CASE
               WHEN ETA.GA_XA_CNL LIKE '1%'
                    AND ETA.GA_XA_CNL || ETA.GA_XA_AT <> '11041'
               THEN ETA.GA_XA_CNL || '_' || ETA.GA_XA_AT
               ELSE ETA.GA_XA_CNL
           END

ORDER BY INT.ID_TABULACAO DESC
