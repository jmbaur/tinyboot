# Boot Flow

pseudo-code:

```
foreach loader in boot_loaders:
    boot_devices = loader.probe()
    foreach device in boot_devices:
        device.boot()
```
