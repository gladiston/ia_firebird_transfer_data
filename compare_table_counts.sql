/* -------------------------------------------------------------------------
   Script: compare_table_counts.sql
   Objetivo: Comparar a quantidade de registros de todas as tabelas de usuário
             entre o banco conectado e outro banco remoto.
   Detalhes:
     - Ignora tabelas de sistema (com '$' no nome).
     - Retorna: TableName, RowCountLocal, RowCountRemote, DiffCount.
     - Se a tabela não existir no banco remoto, RowCountRemote = -1
       e DiffCount = NULL.

   Autor: Gladiston Santana <gladiston.santana[em]gmail.com>
   Uso:
     isql localhost/8050:meubanco.fdb -user SYSDBA -password masterkey -e -i compare_table_counts.sql

   Licença: Uso interno. Proibida a reprodução sem autorização prévia por escrito.
   Criado em: 04/09/2025
   Ult. Atualização: 04/09/2025
------------------------------------------------------------------------- */


execute block
returns (
    TableName      varchar(63),
    RowCountLocal  bigint,
    RowCountRemote bigint,
    DiffCount      bigint
)
as
  declare vSQL            varchar(255);
  declare vSQL_Compare    varchar(255);
  declare vSQL_Check      varchar(255);
  declare vTableName      varchar(63);
  declare vCountLocal     bigint;
  declare vCountCompare   bigint;
  -- comparar com qual banco de dados, usuario, senha
  declare vDB_FROM_HOST     varchar(255) = 'localhost';
  declare vDB_FROM_PORT     varchar(10)  = '3050';
  declare vDB_FROM_DATABASE varchar(255) = 'fontedecomparacao.fdb';
  declare vDB_FROM_USERNAME varchar(63)  = 'SYSDBA';
  declare vDB_FROM_PASSWORD varchar(63)  = 'masterkey';
  declare vDB_FROM_CONN     varchar(512);
begin
  vDB_FROM_CONN = vDB_FROM_HOST || '/' || vDB_FROM_PORT || ':' || vDB_FROM_DATABASE;

  for
    select trim(rdb$relation_name)
    from rdb$relations
    where rdb$system_flag = 0
      and rdb$view_blr is null
      and rdb$relation_name not like '%$%'
    order by rdb$relation_name
    into :vTableName
  do
  begin
    -- Contagem local
    vSQL = 'select count(*) from ' || vTableName;
    execute statement vSQL into :vCountLocal;

    -- Verifica existência no remoto (tabelas de usuário, não-views)
    vSQL_Check =
      'select count(*) from rdb$relations '||
      'where rdb$relation_name = ''' || vTableName || ''' '||
      'and rdb$system_flag = 0 and rdb$view_blr is null';

    execute statement vSQL_Check
      on external :vDB_FROM_CONN
        as user :vDB_FROM_USERNAME
        password :vDB_FROM_PASSWORD
      into :vCountCompare;

    if (vCountCompare = 0) then
    begin
      RowCountRemote = -1;
      DiffCount      = null;
    end
    else
    begin
      vSQL_Compare = 'select count(*) from ' || vTableName;
      execute statement vSQL_Compare
        on external :vDB_FROM_CONN
          as user :vDB_FROM_USERNAME
          password :vDB_FROM_PASSWORD
        into :vCountCompare;
      RowCountRemote = vCountCompare;
      DiffCount      = vCountLocal - vCountCompare;
    end

    TableName      = vTableName;
    RowCountLocal  = vCountLocal;
    suspend;
  end
end
