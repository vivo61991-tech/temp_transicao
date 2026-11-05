# Base Nexus Centralizada — Fase 1

## 1. Objetivo

Centralizar, numa única base, a regra que hoje está copiada dentro de cada view dos relatórios Power BI do Suporte Nexus, **sem alterar nenhum número**.

Hoje cada alteração de regra (já foram 11) precisa ser repetida em cada view. Com a base central, a regra fica em **um único script** e todos os relatórios passam a ler dela.

**Nesta fase não há mudança de regra.** Os relatórios continuam mostrando exatamente o que mostram hoje: mesmas linhas, mesmas colunas, mesmos valores. Correções e evoluções ficam para as próximas fases (seção 8).

```
PORTALINTEGRA_TABULADOR_B2C ─┐
B2C_SUPORTE_MAGIC_M ─────────┤
TB_REGRA_MAGIC_NEXUS ────────┤                               ┌─► VW_NEXUS_SUPORTE_B2C        (= POWERBI_SUPORTE_B2C_NEXUS)
ANALYT_COLABORADORES_HIST ───┼─► MV_NEXUS_SUPORTE_CENTRAL ───┤
DE_PARA_LOCALIDADE ──────────┤    (regra atual, centralizada) └─► VW_NEXUS_DEPENDENCIA_CAMPO  (= POWERBI_DEPENDENCIA_NEXUS)
BI_ETA_DIRECT ───────────────┤
ANALYT_REGIONAIS ────────────┘
```

## 2. Como a base foi montada

A base foi gerada a partir do **texto das duas views de produção**, sem reescrever a regra:

- **Parte 1** — a consulta da `POWERBI_SUPORTE_B2C_NEXUS`, linha por linha.
- **Parte 2** — a consulta da `POWERBI_DEPENDENCIA_NEXUS`, linha por linha. Os blocos internos foram apenas renomeados com o prefixo `DEP_`, para não colidir com os da parte 1. As colunas calculadas entram na base com o prefixo `DEP_`.

**Por que dois cálculos?** Hoje os dois relatórios **não usam exatamente a mesma regra**: o desempate do Beatrix, a comparação da API do Magic e a fonte da localidade são diferentes entre eles (seção 7). Para nenhum número mudar, a base guarda os dois cálculos lado a lado, e cada relatório lê o seu. A unificação é uma decisão para uma fase seguinte.

A tabela de regras continua sendo a **`TB_REGRA_MAGIC_NEXUS` atual**. Alterações nela passam a valer para os dois relatórios na próxima atualização da base.

## 3. Conteúdo da pasta

| Arquivo | Descrição |
|---|---|
| `sql/01_base_central.sql` | Cria a materialized view `MV_NEXUS_SUPORTE_CENTRAL`, os índices e o job de atualização |
| `sql/02_views_relatorios.sql` | Cria `VW_NEXUS_SUPORTE_B2C` e `VW_NEXUS_DEPENDENCIA_CAMPO` |
| `sql/03_conferencia.sql` | Compara, no próprio Oracle, as views atuais com as novas (somente leitura) |
| `referencia/` | Texto das duas views de produção usado para gerar a base |

## 4. Implantação

### 4.1 Pré-requisitos

- Permissão para `CREATE MATERIALIZED VIEW`, `CREATE VIEW`, `CREATE INDEX` e `CREATE JOB`.
- `SELECT` **concedido diretamente ao usuário** dono da MV (não via role, pois o job roda em PL/SQL) nas tabelas:
  - `PORTALINTEGRA_TABULADOR_B2C`
  - `B2C_SUPORTE_MAGIC_M`
  - `TB_REGRA_MAGIC_NEXUS`
  - `ANALYT_COLABORADORES_HIST`
  - `DE_PARA_LOCALIDADE`
  - `BI_ETA_DIRECT`
  - `ANALYT_REGIONAIS`
- Os nomes das tabelas estão sem schema, como nas views atuais. Se o usuário for outro, criar sinônimos ou prefixar.

### 4.2 Ordem

1. `01_base_central.sql` — executar como script (F5 no SQL Developer), pois o final cria o job.
2. `02_views_relatorios.sql`
3. `03_conferencia.sql` — seguir as instruções do cabeçalho. **Todas as diferenças devem dar zero.**
4. Com a conferência zerada, trocar a fonte no Power BI:
   - `POWERBI_SUPORTE_B2C_NEXUS` → `VW_NEXUS_SUPORTE_B2C`
   - `POWERBI_DEPENDENCIA_NEXUS` → `VW_NEXUS_DEPENDENCIA_CAMPO`

   As colunas têm os mesmos nomes, então as medidas e os visuais não precisam ser alterados.
5. Manter as views antigas por um período de convivência e só então desligá-las.

### 4.3 Atualização

- Job `JOB_REFRESH_NEXUS_CENTRAL`, **a cada 1 hora** (ajustável em `repeat_interval`). Deve terminar antes do horário de atualização do Power BI.
- A atualização é atômica: os relatórios continuam vendo a versão anterior até ela terminar.
- Atualização manual:
  ```sql
  EXEC DBMS_MVIEW.REFRESH('MV_NEXUS_SUPORTE_CENTRAL', 'C', atomic_refresh => TRUE);
  ```
- Diferença em relação a hoje: as views atuais calculam na hora da consulta; a base reflete a última atualização. Com a atualização a cada hora e o Power BI atualizado depois dela, o relatório mostra o mesmo resultado.

### 4.4 Desfazer

```sql
BEGIN DBMS_SCHEDULER.DROP_JOB('JOB_REFRESH_NEXUS_CENTRAL'); END;
/
DROP VIEW VW_NEXUS_DEPENDENCIA_CAMPO;
DROP VIEW VW_NEXUS_SUPORTE_B2C;
DROP MATERIALIZED VIEW MV_NEXUS_SUPORTE_CENTRAL;
```

Nenhum objeto existente é alterado; as views atuais continuam funcionando durante e depois da implantação.

## 5. O que tem na base

**Todas as colunas da `POWERBI_SUPORTE_B2C_NEXUS`**, com os mesmos nomes e valores.

**Campos do tabulador mantidos como a operação preencheu**, para análise:
- `PRODUTO_ORIGINAL`, `TIPO_OS`, `TIPO_OPERADOR`, `OBSERVACAO`, `STATUS`, `VALIDADO`, `MAGIC`
- `MAGIC_UTILIZADO` (flag do operador)
- `TECNICO_MATRICULA`, `TECNICO_NOME`, `TECNICO_EMPRESA`
- `CIDADE_TABULADOR`, `ESTADO_TABULADOR`

**Colunas da regra da Dependência** (prefixo `DEP_`):
- `DEP_DT_INICIO_MAGIC`, `DEP_API`, `DEP_FUNCIONALIDADE`, `DEP_FUNCIONALIDADE_MAGIC`
- `DEP_MATRICULA`, `DEP_TECNICO`, `DEP_CONTRATO`, `DEP_CNL`, `DEP_AT`
- `DEP_REGIONAL`, `DEP_CLUSTER`, `DEP_REGIONAL_ACRONIMO`, `DEP_UF`, `DEP_ESTADO`, `DEP_CIDADE`, `DEP_CLUSTER_LATITUDE`, `DEP_CLUSTER_LONGITUDE`
- `DEP_TIPO`, `DEP_CATEGORIA`, `DEP_CATEGORIA_DETALHE`

**Controle:**
- `FLAG_DEPENDENCIA` — 1 quando a linha pertence ao relatório de Dependência.
- `SEQ_LINHA` — ordem da linha quando a mesma tabulação se repete. A view atual do Suporte repete linhas quando há cadastro duplicado; ver seção 7.
- `DT_ATUALIZACAO_BASE` — data e hora da última atualização.

A view da Dependência continua **sem nenhum dado de quem atendeu**.

## 6. Certificação

Antes da entrega, as **views de produção (texto exato)** e as **views novas** foram executadas sobre os mesmos dados e comparadas **linha a linha, em todas as colunas, incluindo linhas repetidas**:

| Conjunto de dados | Suporte | Dependência |
|---|---|---|
| Extração real de 26/10/2026 | 3.985 de 3.985 linhas idênticas | 3.443 de 3.443 idênticas |
| Sintético com data e hora — semente 1 | 2.931 de 2.931 idênticas | 2.266 de 2.266 idênticas |
| Sintético com data e hora — semente 2 | 2.908 de 2.908 idênticas | 2.225 de 2.225 idênticas |
| Sintético com data e hora — semente 3 | 2.908 de 2.908 idênticas | 2.219 de 2.219 idênticas |

Os dados sintéticos cobrem:
- execuções do Magic antes e depois da ligação;
- API com maiúsculas e espaços;
- carga-psa e checklist-vlan na mesma atividade;
- Beatrix com CRM e tipo de OS variados e vazios;
- rechamadas, quedas e solução vazia;
- colaborador e localidade duplicados;
- Vivo2 de SP sem área telefônica.

Para provar que a comparação detecta diferenças, foram feitas **três alterações propositais na regra** (desempate do Beatrix, horário do Magic e ajuste de fuso). As três foram reprovadas.

A conferência final é a do próprio Oracle (`03_conferencia.sql`).

## 7. Achados nas views atuais (não corrigidos nesta fase)

Levantados durante a análise e mantidos **exatamente como estão**, para os números não mudarem. Ficam registrados para decisão nas próximas fases.

1. **Regra que nunca é aplicada.** Na `TB_REGRA_MAGIC_NEXUS`, o problema `'Serial não associado '` está gravado com um espaço no final. As views comparam o texto exato, então essa regra não casa com nenhuma tabulação, e esses atendimentos não passam pela verificação do Magic (108 tabulações em 26/10). Para conferir:
   ```sql
   SELECT '[' || PROBLEMA_ENCONTRADO || ']' FROM TB_REGRA_MAGIC_NEXUS WHERE PROBLEMA_ENCONTRADO LIKE 'Serial%';
   ```
2. **Linhas repetidas no Suporte.** A ligação com `ANALYT_COLABORADORES_HIST` repete a tabulação quando o colaborador tem dois cadastros no mesmo mês. Na extração, isso ocorre com 2 matrículas em 05/2026 (um cadastro "EM PRODUCAO" e outro "DESLIGADO"). Pode ocorrer também com `DE_PARA_LOCALIDADE`, se houver chave repetida.
3. **As duas views não usam a mesma regra do Magic**, então a mesma tabulação pode ter categorias diferentes nos dois relatórios (8 casos em 26/10):
   - **Desempate do Beatrix:** a correção registrada no comentário da view do Suporte, como "aplicada também na Dependência", não está na view da Dependência.
   - **Comparação da API:** a Dependência não trata carga-psa e checklist-vlan como a mesma família e compara o texto sem ignorar maiúsculas e espaços.
4. **Queda de ligação no Suporte.** O `TIPO` vira "Improdutivo" só para a solução "Queda de Ligação". A solução "Encerramento queda ligação" (175 em 26/10) fica como "Devido".
5. **Localidade.** O Suporte não localiza a Vivo2 de SP sem área telefônica, como Araraquara (11041) e Jundiaí (11326). A Dependência trata só o 11041, com uma exceção fixa no código. As duas usam fontes diferentes: `DE_PARA_LOCALIDADE` com a CNL do tabulador, e `ANALYT_REGIONAIS` com a CNL do ETA.
6. **Escolha não determinística.** A deduplicação do `BI_ETA_DIRECT` e da `ANALYT_REGIONAIS` ordena pela própria chave. Quando há duplicidade com conteúdo diferente, a linha escolhida pode variar entre execuções. Hoje as duplicidades da `ANALYT_REGIONAIS` diferem só em `AT_NOME`, que a Dependência não usa.
7. **Trecho sem efeito.** O `TIPO` vazio para atendimentos antes de 12/11/2025 não tem efeito, porque a janela atual começa em 2026.

## 8. Próximas fases (propostas, a validar com as áreas)

1. Corrigir os achados da seção 7, um por vez, cada um com a medição do impacto antes de aplicar.
2. Subir a tabela de regras v14, com a solução aplicada como 4ª chave.
3. Unificar a regra do Magic entre os dois relatórios.
4. Regra dos 10 minutos e avaliação pelas duas datas do Magic.
5. Novos indicadores: conduta do operador (recusa e tempo de recusa) e tratamento de improdutivo e indefinido.

Com a base centralizada, cada uma dessas mudanças passa a ser feita em um único lugar.
