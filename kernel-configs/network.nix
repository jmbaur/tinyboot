{ config, lib, ... }:
{
  linux.kconfig = lib.mkIf config.network (
    with lib.kernel;
    {
      ETHERNET = yes;
      INET = yes;
      IPV6 = yes;
      NETDEVICES = yes;
      NET_CORE = yes;
    }
  );
}
