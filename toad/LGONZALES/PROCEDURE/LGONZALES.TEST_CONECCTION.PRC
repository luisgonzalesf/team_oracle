CREATE OR REPLACE PROCEDURE LGONZALES.TEST_CONECCTION
IS
    cursor cur_articulos is select * from sysadm.articulos where fechareg >=sysdate -7 or fecha_modificacion >= sysdate -7;
    cursor cur_um_articulo is select * from sysadm.UM_POR_ARTICULO;
    V_ARTICULOS UTL_FILE.FILE_TYPE; 
    V_UM_ARTICULO UTL_FILE.FILE_TYPE; 
BEGIN
    V_ARTICULOS := UTL_FILE.FOPEN('BACKUP' , 'articulos.csv' , 'w', 32000 );
    FOR CUR_ART IN cur_articulos
    LOOP
        UTL_FILE.PUT_LINE ( V_ARTICULOS , 
                           CUR_ART.COD_CIA || '|' || 
                           CUR_ART.COD_ITEM || '|' || 
                           --CUR_ART.COD_PROVEEDOR || '|' || 
                           CUR_ART.DESC_ITEM  || '|' || 
                           CUR_ART.UM_COMPRA || '|' || 
                           CUR_ART.UM_VENTA || '|' || 
                           CUR_ART.UM_CONTROL_STOCK  || '|' ||
                           CUR_ART.ALMACEN_VENTA  || '|' ||
                           CUR_ART.REG_SANIT || '|' || 
                           TO_CHAR(CUR_ART.F_EMI_REGSAN, 'DD-MM-YYYY')  || '|' || 
                           TO_CHAR(CUR_ART.F_VCMTO_REGSAN, 'DD-MM-YYYY') || '|' || 
                           CUR_ART.COMPANIA_VENTA || '|' || 
                           CUR_ART.ALMACEN_VENTA  || '|' ||
                           CUR_ART.MONEDA_VENTA || '|' || 
                           CUR_ART.DESC_SGS || '|' || 
                           CUR_ART.TAX_SELECTIVO || '|' || 
                           CUR_ART.STATUS_ITEM || '|' || 
                           CUR_ART.CLASE || '|' || 
                           CUR_ART.SUBCLASE || '|' || 
                           CUR_ART.DESC_COMPRAS || '|' || 
                           CUR_ART.TAX_IGV || '|' || 
                           TO_CHAR(CUR_ART.PORCENTAJE_ISC, 'fm9999999990,0000') || '|' || 
                           TO_CHAR(CUR_ART.PORCENTAJE_IGV, 'fm9999999990,0000') || '|' || 
                           TO_CHAR(CUR_ART.VOLUMEN_REF, 'fm9999999990,0000') || '|' || 
                           CUR_ART.FLAG_DEALOK || '|' || 
                           CUR_ART.COD_LINEA || '|' || 
                           TO_CHAR(CUR_ART.FECHA_MODIFICACION, 'DD-MM-YYYY') || '|' || 
                           TO_CHAR(CUR_ART.COSTO_UNI, 'fm9999999990,0000') || '|' || 
                           CUR_ART.CARACT1 || '|' || 
                           CUR_ART.CARACT2 || '|' || 
                           CUR_ART.PROVEEDOR_DEFAULT || '|' || 
                           CUR_ART.CARACT3 || '|' || 
                           CUR_ART.CARACT4 || '|' || 
                           CUR_ART.FLAG_DEAL || '|' || 
                           CUR_ART.FLAG_LOTE || '|' || 
                           CUR_ART.LOTE_DEFAULT || '|' || 
                           CUR_ART.ULTIMO_LOTE || '|' || 
                           CUR_ART.ESTADO || '|' || 
                           CUR_ART.ZONA || '|' || 
                           CUR_ART.RACK || '|' || 
                           CUR_ART.NIVEL || '|' ||
                           CUR_ART.CASILLERO || '|' ||
                           CUR_ART.PALLET || '|' ||
                           CUR_ART.CRITICO || '|' ||
                           CUR_ART.SENSIBLE || '|' ||
                           CUR_ART.COD_BARRAS || '|' ||
                           TO_CHAR(CUR_ART.PESO, 'fm9999999990,0000')  || '|' ||
                           CUR_ART.ROWVERSION || '|' ||
                           TO_CHAR(CUR_ART.STOCK_SEGURIDAD, 'fm9999999990,0000') || '|' ||
                           CUR_ART.TIPO_ROTACION || '|' ||
                           CUR_ART.CODIGO_ANTIGUO || '|' ||
                           CUR_ART.CODIGO_PARTIDA || '|' ||
                           CUR_ART.FLAG_NRO_SERIE || '|' ||
                           TO_CHAR(CUR_ART.TIEMPO_GARANTIA, 'fm9999999990,0000') || '|' ||
                           CUR_ART.FLAG_GARANTIA_INF || '|' ||
                           CUR_ART.ORDEN_INGRESO || '|' ||
                           TO_CHAR(CUR_ART.LARGO, 'fm9999999990,0000') || '|' ||
                           TO_CHAR(CUR_ART.ANCHO, 'fm9999999990,0000') || '|' ||
                           TO_CHAR(CUR_ART.ALTO, 'fm9999999990,0000') || '|' ||
                           CUR_ART.MAX_APILAR || '|' ||
                           TO_CHAR(CUR_ART.QTY_DISPONIBLE, 'fm9999999990,0000') || '|' ||
                           TO_CHAR(CUR_ART.QTY_RESERVADA, 'fm9999999990,0000') || '|' ||
                           CUR_ART.FLAG_ACTIVO || '|' ||
                           CUR_ART.COD_TIPOACTIVO|| '|' ||
                           CUR_ART.BART_PRODTERMINADO || '|' ||
                           CUR_ART.BART_PRODINTERMED || '|' ||
                           CUR_ART.BART_INSUMO || '|' ||
                           CUR_ART.CART_UMPRODUCCION || '|' ||
                           CUR_ART.QART_DIASENTREGA || '|' ||
                           TO_CHAR(CUR_ART.QART_LOTEMINIMPROD, 'fm9999999990,0000') || '|' ||
                           TO_CHAR(CUR_ART.QART_LOTEMINIMCOMP, 'fm9999999990,0000') || '|' ||
                           TO_CHAR(CUR_ART.QART_MULTIPLOCOMP, 'fm9999999990,0000') || '|' ||
                           CUR_ART.QART_VERSION || '|' ||
                           CUR_ART.BART_PRODCONTROLADO || '|' ||
                           CUR_ART.PART_CONCENTRACION || '|' ||
                           CUR_ART.COD_IQPF || '|' ||
                           CUR_ART.FLAG_PERCEPCION || '|' ||
                           CUR_ART.ID_PROVEEDOR || '|' ||
                           CUR_ART.FLAG_BEBIDAS || '|' ||
                           CUR_ART.TAX_IVAP || '|' ||
                           CUR_ART.TAX_PERCEPCION || '|' ||
                           TO_CHAR(CUR_ART.PORCENTAJE_IVAP, 'fm9999999990,0000') || '|' ||
                           TO_CHAR(CUR_ART.PORCENTAJE_PERCEPCION, 'fm9999999990,0000') || '|' ||
                           CUR_ART.TIPO_ITEM || '|' ||
                           CUR_ART.USUAR_DESAC || '|' ||
                           TO_CHAR(CUR_ART.FECHA_DESAC, 'DD-MM-YYYY') || '|' ||
                           CUR_ART.USUARIOREG || '|' ||
                           TO_CHAR(CUR_ART.FECHAREG, 'DD-MM-YYYY') || '|' ||
                           CUR_ART.USUARIOMOD || '|' ||
                           CUR_ART.ID_CLASE || '|' ||
                           CUR_ART.ID_SUBTI || '|' ||
                           CUR_ART.ID_VARIE || '|' ||
                           CUR_ART.ID_PRESE || '|' ||
                           CUR_ART.ID_CATEGORIA || '|' ||
                           CUR_ART.ID_FAMILIA || '|' ||
                           CUR_ART.ID_MARCA || '|' ||
                           CUR_ART.ID_TIPO || '|' ||
                           CUR_ART.VIDA_UTIL || '|' ||
                           CUR_ART.DESC_ITEM_VENTA || '|' ||
                           CUR_ART.ALTO_DISTRIBUCION || '|' ||
                           CUR_ART.LARGO_DISTRIBUCION || '|' ||
                           CUR_ART.ANCHO_DISTRIBUCION || '|' ||
                           CUR_ART.PESO_DISTRIBUCION || '|' ||
                           CUR_ART.PALLET_BASE || '|' ||
                           CUR_ART.PALLET_ALTO || '|' ||
                           CUR_ART.DESC_ITEM_ORIGEN || '|' ||
                           CUR_ART.COD_PROVEEDOR_EXTERNO || '|' ||
                           CUR_ART.FLG_ARTP || '|' ||
                           CUR_ART.MTRS_CUB_BASE || '|' ||
                           CUR_ART.MTRS_CUB_ALTO || '|' ||
                           CUR_ART.DESC_ITEM_NUEVA || '|' ||
                           CUR_ART.ARTACT || '|' ||
                           CUR_ART.FLAG_ARTCONBONIF || '|' ||
                           CUR_ART.FLAG_ARTBONIF || '|' ||
                           CUR_ART.TIPO_COMBO || '|' ||
                           CUR_ART.COD_ITEM_ORIGEN || '|' ||
                           CUR_ART.FLAG_VTA_DIGITAL || '|' ||
                           CUR_ART.DESC_VTA_DIGITAL || '|' ||
                           CUR_ART.FOTO || '|' ||
                           CUR_ART.DESC_VTA_DIGITAL_COMPLETA || '|' ||
                           CUR_ART.ID_FAMILIA_COMERCIAL || '|' ||
                           CUR_ART.ID_CLASE_COMERCIAL || '|' ||
                           CUR_ART.ID_OCTOGONO1 || '|' ||
                           CUR_ART.ID_OCTOGONO2 || '|' ||
                           CUR_ART.ID_TIPO_COMERCIAL || '|' ||
                           CUR_ART.ID_SUBCLASE_COMERCIAL || '|' ||
                           CUR_ART.ID_SUBCLASE_COMERCIAX || '|' ||
                           TO_CHAR(CUR_ART.FACTOR_PROVEEDOR, 'fm9999999990,0000') || '|' ||
                           CUR_ART.ID_ORIGEN || '|' ||
                           CUR_ART.FLAG_FRIO || '|' ||
                           CUR_ART.DESC_EXTERNA || '|' ||
                           CUR_ART.ALICORP_ITD
                         );
    END LOOP;
    UTL_FILE.FCLOSE( V_ARTICULOS );
    DBMS_OUTPUT.PUT_LINE  ( 'ARCHIVO ARTICULOS GENERADO');
    --------------------------------------------------------------------------------------
    V_UM_ARTICULO := UTL_FILE.FOPEN('BACKUP' , 'um_articulo.csv' , 'w', 32000 );
    FOR CUR_UM_ART IN cur_um_articulo
    LOOP
        UTL_FILE.PUT_LINE ( V_UM_ARTICULO , 
                           CUR_UM_ART.COD_CIA || '|' || 
                           CUR_UM_ART.COD_ITEM || '|' ||
                           CUR_UM_ART.UM_ITEM || '|' ||
                           CUR_UM_ART.ALMACEN || '|' ||
                           CUR_UM_ART.COMPRA || '|' ||
                           CUR_UM_ART.VENTA || '|' ||
                           CUR_UM_ART.ROWVERSION
                           );
    END LOOP;
    UTL_FILE.FCLOSE( V_UM_ARTICULO );
    DBMS_OUTPUT.PUT_LINE  ( 'ARCHIVO UM_ARTICULO GENERADO');
END;
/
