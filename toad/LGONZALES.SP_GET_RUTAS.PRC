CREATE OR REPLACE PROCEDURE LGONZALES.SP_GET_RUTAS(CUR_VENTA OUT SYS_REFCURSOR, CUR_DESPACHO OUT SYS_REFCURSOR, CUR_DETALLE OUT SYS_REFCURSOR)
IS
/*CURSOR CUR_DAT IS 
    SELECT 
        COMPANIA_VENTA_3,
        NRO_INTERNO_GUIA
    FROM SYSADM.GUIAS_HEADER GH	
    WHERE TO_CHAR(GH.FECHA_GUIADO_2,'DD-MM-YYYY')=TO_CHAR(SYSDATE,'DD-MM-YYYY')
        AND GH.SINCRONIZADO != 1
        --AND GH.FLAG_PREASIGNACION != 1
        AND GH.STATUS_GUIA='I'
        AND GH.COD_SEDE='001'
    ;*/
BEGIN   
    OPEN CUR_DESPACHO FOR 
    SELECT IDRUTADESPACHO ID, CODRUTADESPACHO, DESCRUTADESPACHO, CODEMPRESA, CODSEDE, CODFUERZAV, ESTADO 
    FROM SYSADM.RUTA_DESPACHO
    ;
    
    OPEN CUR_VENTA FOR 
    SELECT IDRUTA ID, CODRUTA, DESCRUTA, CODEMPRESA, CODSEDE, DIVISION, CASE ESTADO WHEN 'H' THEN 'A' ELSE ESTADO END ESTADO
    FROM SYSADM.TB_RUTA TR JOIN SYSADM.TB_SEDE TS ON TS.IDSEDE=TR.IDSEDE
    ;
    
    OPEN CUR_DETALLE FOR
    SELECT RDD.IDDETALLE, RDD.IDRUTADESPACHO ID_RUTA_DESPACHO, RDD.IDRUTAVENTA ID_RUTA_VENTA, RDD.ESTADO --RD.CODRUTADESPACHO, TR.CODRUTA, RDD.ESTADO
    FROM SYSADM.RUTA_DESPACHO_DETALLE RDD --JOIN SYSADM.RUTA_DESPACHO RD ON RD.IDRUTADESPACHO=RDD.IDRUTADESPACHO 
        --JOIN SYSADM.TB_RUTA TR ON TR.IDRUTA=RDD.IDRUTAVENTA
    ;
    /*
    FOR CUR IN CUR_DAT
    LOOP
        UPDATE SYSADM.GUIAS_HEADER SET SINCRONIZADO = 1
        WHERE COMPANIA_VENTA_3=CUR.COMPANIA_VENTA_3 AND NRO_INTERNO_GUIA=CUR.NRO_INTERNO_GUIA
        ;
    END LOOP;
    */
    COMMIT;
    DBMS_OUTPUT.PUT_LINE ('OK');
EXCEPTION
    WHEN OTHERS
    THEN
        DBMS_OUTPUT.PUT_LINE ('OCURRIO UN ERROR');
END;
/
