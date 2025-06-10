# Kernel Configuration

Tinyboot requires a small set of kernel configuration to be enabled, see [here](./required.config) for the set of required configuration. All configuration after this can be considered hardware support. For example, to enable a serial console for an x86_64 qemu machine, you could add the following configuration.

```conf
CONFIG_CMDLINE_BOOL=y
CONFIG_CMDLINE="console=ttyS0,115200"
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
```
