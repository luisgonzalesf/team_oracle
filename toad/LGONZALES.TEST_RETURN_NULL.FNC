CREATE OR REPLACE FUNCTION LGONZALES.TEST_RETURN_NULL(OPT NUMBER)RETURN SYS_REFCURSOR IS
    cur_detalle_deposito SYS_REFCURSOR;
BEGIN
    IF OPT = 1 THEN
        RAISE_APPLICATION_ERROR(-20002, 'Error en opción 1');
        --RETURN NULL;
    END IF;
    
    INSERT INTO XRAYADMIN.TEMP_DETALLE_DEPOSITO (CUENTA, DESCRIPCION_CUENTA)
    SELECT cod_item, desc_item FROM sysadm.articulos where cod_item='530269' and rownum <10;
    
    OPEN cur_detalle_deposito FOR 
        SELECT * FROM XRAYADMIN.TEMP_DETALLE_DEPOSITO;

    RETURN cur_detalle_deposito;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error insertando paquete: ' || SQLERRM);
        RAISE; 
END;
/
