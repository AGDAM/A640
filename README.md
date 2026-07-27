# A640 — 68040 Accelerator for the Amiga 600

The **A640** is a hobby hardware project: a 68040-based accelerator card for the Commodore Amiga 600. It plugs into the A600's 68000 CPU socket and adapts the 32-bit 68040 to the machine's native 16-bit bus, adds fast 32-bit SDRAM, and lets you configure the CPU clock in software through an I2C-programmable PLL.

The card is built around a Xilinx **XC95288XL** CPLD that handles the 68040 → 68000 bus conversion, the SDRAM controller, Zorro III autoconfig and the PLL/I2C register interface. A second **XC95144XL** CPLD handles the dynamic 32-bit ↔ 16-bit bus sizing.

---

## Features

- **Motorola 68040** CPU running on the A600 mainboard
- **32-bit SDRAM** (up to 64 MB) directly addressed by the 68040
- **Software-selectable CPU clock** via an NB3N3020 I2C PLL — no jumpers, no soldering to change speed
- **Persistent configuration** stored in a 24LC32 I2C EEPROM (survives power cycles)
- **On-board monitoring** over the same I2C bus: LM75A temperature sensor and DS3231 real-time clock
- **Zorro III autoconfig** so the Fast RAM is registered cleanly by the OS
- Bus logic implemented in two Xilinx CPLDs — **XC95288XL** (main logic) and **XC95144XL** (bus sizing), 5V-tolerant inputs, 3.3V core

---

## Repository layout

Typical contents (names may vary with the version you cloned):

- `main_logic.vhd` — top-level A640 logic for the XC95288XL (bus conversion, SDRAM controller, autoconfig, PLL/I2C interface)
- `dynamic_bus_sizer.vhd` — 32-bit ↔ 16-bit dynamic bus sizer
- SDRAM controller sources
- `*.ucf` — pin constraints for the CPLD
- `A640Monitor` — AmigaOS live monitor and PLL configuration tool (binary and C source)
- `RTC` — AmigaOS tool for the DS3231 real-time clock (binary and C source)

---

## Credits

This project was developed based on **Georg Braun's 68060 turbocard** project, whose design and bus-handling approach served as the reference and starting point for the A640. Many thanks for making that work available to the community.

---

## Disclaimer

This is a **hobby project**, shared as-is for other retrocomputing enthusiasts.

**I take no responsibility for any misuse, damage, or loss** — to your Amiga, the card, connected hardware, or anything else. You build, program and use this project **entirely at your own risk**. There are no warranties of any kind, express or implied, including fitness for a particular purpose. If you are not comfortable working with vintage hardware, custom logic and soldering, please don't proceed.

---

## Support

If you like this project, you can buy me a coffee: **https://buycoffee.to/lukzer** ☕ or PayPal lukzer@gmail.com

Thanks, and have fun tinkering!
