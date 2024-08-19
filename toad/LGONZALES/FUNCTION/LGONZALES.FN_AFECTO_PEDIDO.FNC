CREATE OR REPLACE FUNCTION LGONZALES.FN_AFECTO_PEDIDO(pCOMPANIA_VENTA IN VARCHAR2, pNRO_PEDIDO IN VARCHAR2) RETURN NUMBER
IS
    xMONTO_AFECTO NUMBER;
BEGIN
    select sum(spd.venta_neta) - sum(spd.impuesto_igv) - sum(spd.monto_percepcion) INTO xMONTO_AFECTO
    from sysadm.spedido_detalle spd
    where spd.impuesto_igv > 0
        and spd.compania_venta = pCOMPANIA_VENTA
        and spd.nro_pedido = pNRO_PEDIDO
    ;
    RETURN xMONTO_AFECTO;
END;
/
