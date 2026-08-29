# =============================================================================
# radix.do — Colores personalizados para los estados de FTDI_Controller
# =============================================================================

# 1. Definir el radix basado en los índices del enumerado t_state
radix define ftdi_state_radix {
    # TX / Reposo (Tonos Grises/Apagados)
    "0" "ST_IDLE"       -color "Gray",
    "1" "ST_HOLD"       -color "Cyan",
    
    # RX Bus - 4 fases (Tonos Azules/Cian)
    "2" "ST_RX_OE"      -color "Cyan",
    "3" "ST_RX_OE2"     -color "LightBlue",
    "4" "ST_RX_RD"      -color "Blue",
    "5" "ST_RX_RELEASE" -color "DeepSkyBlue",
    
    # RX Decodificación de Bytes (Tonos Naranjas/Amarillos)
    "6" "ST_CMD_BYTE1"  -color "Orange",
    "7" "ST_CMD_BYTE2"  -color "LightOrange",
    "8" "ST_CMD_BYTE3"  -color "Yellow",
    "9" "ST_CMD_BYTE4"  -color "Gold",
    "10" "ST_CMD_BYTE5" -color "LightYellow",
    "11" "ST_CMD_BYTE6" -color "Khaki",
    
    # RX Ejecución (Verde - ¡Acción!)
    "12" "ST_CMD_EXEC"  -color "Green"
}

# 2. Aplicar el radix a la señal específica del FTDI
#property wave /testbench/u_dut/u_ftdi_ctrl/s_state -radix ftdi_state_radix

# 3. Refrescar la interfaz gráfica para aplicar los cambios visuales inmediatamente
wave refresh