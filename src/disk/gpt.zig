const std = @import("std");
const mem = std.mem;
const io = std.io;

/// expects a guid string formatted like so: 00000000-0000-0000-0000-000000000000
fn guidFromString(str: []const u8) !std.os.uefi.Guid {
    var split = std.mem.splitScalar(u8, str, '-');

    const first_section = split.next().?;
    if (first_section.len != 8) {
        return error.InvalidValue;
    }

    const second_section = split.next() orelse return error.InvalidValue;
    if (second_section.len != 4) {
        return error.InvalidValue;
    }

    const third_section = split.next() orelse return error.InvalidValue;
    if (third_section.len != 4) {
        return error.InvalidValue;
    }

    const fourth_section = split.next() orelse return error.InvalidValue;
    if (fourth_section.len != 4) {
        return error.InvalidValue;
    }

    const fifth_section = split.next() orelse return error.InvalidValue;
    if (fifth_section.len != 12) {
        return error.InvalidValue;
    }

    const guid_bytes = [_]u8{
        try std.fmt.parseInt(u8, first_section[6..8], 16),
        try std.fmt.parseInt(u8, first_section[4..6], 16),
        try std.fmt.parseInt(u8, first_section[2..4], 16),
        try std.fmt.parseInt(u8, first_section[0..2], 16),
        try std.fmt.parseInt(u8, second_section[2..4], 16),
        try std.fmt.parseInt(u8, second_section[0..2], 16),
        try std.fmt.parseInt(u8, third_section[2..4], 16),
        try std.fmt.parseInt(u8, third_section[0..2], 16),
        try std.fmt.parseInt(u8, fourth_section[0..2], 16),
        try std.fmt.parseInt(u8, fourth_section[2..4], 16),
        try std.fmt.parseInt(u8, fifth_section[0..2], 16),
        try std.fmt.parseInt(u8, fifth_section[2..4], 16),
        try std.fmt.parseInt(u8, fifth_section[4..6], 16),
        try std.fmt.parseInt(u8, fifth_section[6..8], 16),
        try std.fmt.parseInt(u8, fifth_section[8..10], 16),
        try std.fmt.parseInt(u8, fifth_section[10..12], 16),
    };
    const guid: std.os.uefi.Guid = @bitCast(guid_bytes);
    return guid;
}

const known_partition_guids = b: {
    @setEvalBranchQuota(100_000);

    const PairHuman = struct { type: PartitionType, guid: []const u8 };
    const PairMachine = struct { type: PartitionType, guid: std.os.uefi.Guid };

    const known = [_]PairHuman{
        PairHuman{ .type = PartitionType.UnusedEntry, .guid = "00000000-0000-0000-0000-000000000000" },
        PairHuman{ .type = PartitionType.MbrPartitionScheme, .guid = "024DEE41-33E7-11D3-9D69-0008C781F39F" },
        PairHuman{ .type = PartitionType.EfiSystem, .guid = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" },
        PairHuman{ .type = PartitionType.BiosBoot, .guid = "21686148-6449-6E6F-744E-656564454649" },
        PairHuman{ .type = PartitionType.IntelFastFlash, .guid = "D3BFE2DE-3DAF-11DF-BA40-E3A556D89593" },
        PairHuman{ .type = PartitionType.SonyBoot, .guid = "F4019732-066E-4E12-8273-346C5641494F" },
        PairHuman{ .type = PartitionType.LenovoBoot, .guid = "BFBFAFE7-A34F-448A-9A5B-6213EB736C22" },
        PairHuman{ .type = PartitionType.WindowsMicrosoftReserved, .guid = "E3C9E316-0B5C-4DB8-817D-F92DF00215AE" },
        PairHuman{ .type = PartitionType.WindowsBasicData, .guid = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7" },
        PairHuman{ .type = PartitionType.WindowsLogicalDiskManagerMetadata, .guid = "5808C8AA-7E8F-42E0-85D2-E1E90434CFB3" },
        PairHuman{ .type = PartitionType.WindowsLogicalDiskManagerData, .guid = "AF9B60A0-1431-4F62-BC68-3311714A69AD" },
        PairHuman{ .type = PartitionType.WindowsWindowsRecoveryEnvironment, .guid = "DE94BBA4-06D1-4D40-A16A-BFD50179D6AC" },
        PairHuman{ .type = PartitionType.WindowsIbmGeneralParallelFileSystem, .guid = "37AFFC90-EF7D-4E96-91C3-2D7AE055B174" },
        PairHuman{ .type = PartitionType.WindowsStorageSpaces, .guid = "E75CAF8F-F680-4CEE-AFA3-B001E56EFC2D" },
        PairHuman{ .type = PartitionType.WindowsStorageReplica, .guid = "558D43C5-A1AC-43C0-AAC8-D1472B2923D1" },
        PairHuman{ .type = PartitionType.HpUxData, .guid = "75894C1E-3AEB-11D3-B7C1-7B03A0000000" },
        PairHuman{ .type = PartitionType.HpUxService, .guid = "E2A1E728-32E3-11D6-A682-7B03A0000000" },
        PairHuman{ .type = PartitionType.LinuxFilesystemData, .guid = "0FC63DAF-8483-4772-8E79-3D69D8477DE4" },
        PairHuman{ .type = PartitionType.LinuxRaid, .guid = "A19D880F-05FC-4D3B-A006-743F0F84911E" },
        PairHuman{ .type = PartitionType.LinuxRootAlpha, .guid = "6523F8AE-3EB1-4E2A-A05A-18B695AE656F" },
        PairHuman{ .type = PartitionType.LinuxRootArc, .guid = "D27F46ED-2919-4CB8-BD25-9531F3C16534" },
        PairHuman{ .type = PartitionType.LinuxRootArm, .guid = "69DAD710-2CE4-4E3C-B16C-21A1D49ABED3" },
        PairHuman{ .type = PartitionType.LinuxRootAarch64, .guid = "B921B045-1DF0-41C3-AF44-4C6F280D3FAE" },
        PairHuman{ .type = PartitionType.LinuxRootIA64, .guid = "993D8D3D-F80E-4225-855A-9DAF8ED7EA97" },
        PairHuman{ .type = PartitionType.LinuxRootLoongArch64, .guid = "77055800-792C-4F94-B39A-98C91B762BB6" },
        PairHuman{ .type = PartitionType.LinuxRootMipsel, .guid = "37C58C8A-D913-4156-A25F-48B1B64E07F0" },
        PairHuman{ .type = PartitionType.LinuxRootMips64el, .guid = "700BDA43-7A34-4507-B179-EEB93D7A7CA3" },
        PairHuman{ .type = PartitionType.LinuxRootPaRisc, .guid = "1AACDB3B-5444-4138-BD9E-E5C2239B2346" },
        PairHuman{ .type = PartitionType.LinuxRootPpc32, .guid = "1DE3F1EF-FA98-47B5-8DCD-4A860A654D78" },
        PairHuman{ .type = PartitionType.LinuxRootPpc64Be, .guid = "912ADE1D-A839-4913-8964-A10EEE08FBD2" },
        PairHuman{ .type = PartitionType.LinuxRootPpc64Le, .guid = "C31C45E6-3F39-412E-80FB-4809C4980599" },
        PairHuman{ .type = PartitionType.LinuxRootRiscv32, .guid = "60D5A7FE-8E7D-435C-B714-3DD8162144E1" },
        PairHuman{ .type = PartitionType.LinuxRootRiscv64, .guid = "72EC70A6-CF74-40E6-BD49-4BDA08E8F224" },
        PairHuman{ .type = PartitionType.LinuxRootS390, .guid = "08A7ACEA-624C-4A20-91E8-6E0FA67D23F9" },
        PairHuman{ .type = PartitionType.LinuxRootS390x, .guid = "5EEAD9A9-FE09-4A1E-A1D7-520D00531306" },
        PairHuman{ .type = PartitionType.LinuxRootTileGx, .guid = "C50CDD70-3862-4CC3-90E1-809A8C93EE2C" },
        PairHuman{ .type = PartitionType.LinuxRootX64, .guid = "44479540-F297-41B2-9AF7-D131D5F0458A" },
        PairHuman{ .type = PartitionType.LinuxRootX86_64, .guid = "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709" },
        PairHuman{ .type = PartitionType.LinuxUsrAlpha, .guid = "E18CF08C-33EC-4C0D-8246-C6C6FB3DA024" },
        PairHuman{ .type = PartitionType.LinuxUsrArc, .guid = "7978A683-6316-4922-BBEE-38BFF5A2FECC" },
        PairHuman{ .type = PartitionType.LinuxUsrArm, .guid = "7D0359A3-02B3-4F0A-865C-654403E70625" },
        PairHuman{ .type = PartitionType.LinuxUsrAarch64, .guid = "B0E01050-EE5F-4390-949A-9101B17104E9" },
        PairHuman{ .type = PartitionType.LinuxUsrIA64, .guid = "4301D2A6-4E3B-4B2A-BB94-9E0B2C4225EA" },
        PairHuman{ .type = PartitionType.LinuxUsrLoongArch64, .guid = "E611C702-575C-4CBE-9A46-434FA0BF7E3F" },
        PairHuman{ .type = PartitionType.LinuxUsrMipsel, .guid = "0F4868E9-9952-4706-979F-3ED3A473E947" },
        PairHuman{ .type = PartitionType.LinuxUsrMips64el, .guid = "C97C1F32-BA06-40B4-9F22-236061B08AA8" },
        PairHuman{ .type = PartitionType.LinuxUsrPaRisc, .guid = "DC4A4480-6917-4262-A4EC-DB9384949F25" },
        PairHuman{ .type = PartitionType.LinuxUsrPpc32, .guid = "7D14FEC5-CC71-415D-9D6C-06BF0B3C3EAF" },
        PairHuman{ .type = PartitionType.LinuxUsrPpc64Be, .guid = "2C9739E2-F068-46B3-9FD0-01C5A9AFBCCA" },
        PairHuman{ .type = PartitionType.LinuxUsrPpc64Le, .guid = "15BB03AF-77E7-4D4A-B12B-C0D084F7491C" },
        PairHuman{ .type = PartitionType.LinuxUsrRiscv32, .guid = "B933FB22-5C3F-4F91-AF90-E2BB0FA50702" },
        PairHuman{ .type = PartitionType.LinuxUsrRiscv64, .guid = "BEAEC34B-8442-439B-A40B-984381ED097D" },
        PairHuman{ .type = PartitionType.LinuxUsrS390, .guid = "CD0F869B-D0FB-4CA0-B141-9EA87CC78D66" },
        PairHuman{ .type = PartitionType.LinuxUsrS390x, .guid = "8A4F5770-50AA-4ED3-874A-99B710DB6FEA" },
        PairHuman{ .type = PartitionType.LinuxUsrTileGx, .guid = "55497029-C7C1-44CC-AA39-815ED1558630" },
        PairHuman{ .type = PartitionType.LinuxUsrX64, .guid = "75250D76-8CC6-458E-BD66-BD47CC81A812" },
        PairHuman{ .type = PartitionType.LinuxUsrX86_64, .guid = "8484680C-9521-48C6-9C11-B0720656F69E" },
        PairHuman{ .type = PartitionType.LinuxRootVerityAlpha, .guid = "FC56D9E9-E6E5-4C06-BE32-E74407CE09A5" },
        PairHuman{ .type = PartitionType.LinuxRootVerityArc, .guid = "24B2D975-0F97-4521-AFA1-CD531E421B8D" },
        PairHuman{ .type = PartitionType.LinuxRootVerityArm, .guid = "7386CDF2-203C-47A9-A498-F2ECCE45A2D6" },
        PairHuman{ .type = PartitionType.LinuxRootVerityAarch64, .guid = "DF3300CE-D69F-4C92-978C-9BFB0F38D820" },
        PairHuman{ .type = PartitionType.LinuxRootVerityIA64, .guid = "86ED10D5-B607-45BB-8957-D350F23D0571" },
        PairHuman{ .type = PartitionType.LinuxRootVerityLoongArch64, .guid = "F3393B22-E9AF-4613-A948-9D3BFBD0C535" },
        PairHuman{ .type = PartitionType.LinuxRootVerityMipsel, .guid = "D7D150D2-2A04-4A33-8F12-16651205FF7B" },
        PairHuman{ .type = PartitionType.LinuxRootVerityMips64el, .guid = "16B417F8-3E06-4F57-8DD2-9B5232F41AA6" },
        PairHuman{ .type = PartitionType.LinuxRootVerityPaRisc, .guid = "D212A430-FBC5-49F9-A983-A7FEEF2B8D0E" },
        PairHuman{ .type = PartitionType.LinuxRootVerityPpc32, .guid = "906BD944-4589-4AAE-A4E4-DD983917446A" },
        PairHuman{ .type = PartitionType.LinuxRootVerityPpc64Be, .guid = "9225A9A3-3C19-4D89-B4F6-EEFF88F17631" },
        PairHuman{ .type = PartitionType.LinuxRootVerityPpc64Le, .guid = "98CFE649-1588-46DC-B2F0-ADD147424925" },
        PairHuman{ .type = PartitionType.LinuxRootVerityRiscv32, .guid = "AE0253BE-1167-4007-AC68-43926C14C5DE" },
        PairHuman{ .type = PartitionType.LinuxRootVerityRiscv64, .guid = "B6ED5582-440B-4209-B8DA-5FF7C419EA3D" },
        PairHuman{ .type = PartitionType.LinuxRootVerityS390, .guid = "7AC63B47-B25C-463B-8DF8-B4A94E6C90E1" },
        PairHuman{ .type = PartitionType.LinuxRootVerityS390x, .guid = "B325BFBE-C7BE-4AB8-8357-139E652D2F6B" },
        PairHuman{ .type = PartitionType.LinuxRootVerityTileGx, .guid = "966061EC-28E4-4B2E-B4A5-1F0A825A1D84" },
        PairHuman{ .type = PartitionType.LinuxRootVerityX64, .guid = "2C7357ED-EBD2-46D9-AEC1-23D437EC2BF5" },
        PairHuman{ .type = PartitionType.LinuxRootVerityX86_64, .guid = "D13C5D3B-B5D1-422A-B29F-9454FDC89D76" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityAlpha, .guid = "8CCE0D25-C0D0-4A44-BD87-46331BF1DF67" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityArc, .guid = "FCA0598C-D880-4591-8C16-4EDA05C7347C" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityArm, .guid = "C215D751-7BCD-4649-BE90-6627490A4C05" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityAarch64, .guid = "6E11A4E7-FBCA-4DED-B9E9-E1A512BB664E" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityIA64, .guid = "6A491E03-3BE7-4545-8E38-83320E0EA880" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityLoongArch64, .guid = "F46B2C26-59AE-48F0-9106-C50ED47F673D" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityMipsel, .guid = "46B98D8D-B55C-4E8F-AAB3-37FCA7F80752" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityMips64el, .guid = "3C3D61FE-B5F3-414D-BB71-8739A694A4EF" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityPaRisc, .guid = "5843D618-EC37-48D7-9F12-CEA8E08768B2" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityPpc32, .guid = "EE2B9983-21E8-4153-86D9-B6901A54D1CE" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityPpc64Be, .guid = "BDB528A5-A259-475F-A87D-DA53FA736A07" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityPpc64Le, .guid = "DF765D00-270E-49E5-BC75-F47BB2118B09" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityRiscv32, .guid = "CB1EE4E3-8CD0-4136-A0A4-AA61A32E8730" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityRiscv64, .guid = "8F1056BE-9B05-47C4-81D6-BE53128E5B54" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityS390, .guid = "B663C618-E7BC-4D6D-90AA-11B756BB1797" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityS390x, .guid = "31741CC4-1A2A-4111-A581-E00B447D2D06" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityTileGx, .guid = "2FB4BF56-07FA-42DA-8132-6B139F2026AE" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityX64, .guid = "77FF5F63-E7B6-4633-ACF4-1565B864C0E6" },
        PairHuman{ .type = PartitionType.LinuxUsrVerityX86_64, .guid = "8F461B0D-14EE-4E81-9AA9-049B6FB97ABD" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignatureAlpha, .guid = "D46495B7-A053-414F-80F7-700C99921EF8" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignatureArc, .guid = "143A70BA-CBD3-4F06-919F-6C05683A78BC" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignatureArm, .guid = "42B0455F-EB11-491D-98D3-56145BA9D037" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignatureAarch64, .guid = "6DB69DE6-29F4-4758-A7A5-962190F00CE3" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignatureIA64, .guid = "E98B36EE-32BA-4882-9B12-0CE14655F46A" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignatureLoongArch64, .guid = "5AFB67EB-ECC8-4F85-AE8E-AC1E7C50E7D0" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignatureMipsel, .guid = "C919CC1F-4456-4EFF-918C-F75E94525CA5" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignatureMips64el, .guid = "904E58EF-5C65-4A31-9C57-6AF5FC7C5DE7" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignaturePaRisc, .guid = "15DE6170-65D3-431C-916E-B0DCD8393F25" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignaturePpc32, .guid = "D4A236E7-E873-4C07-BF1D-BF6CF7F1C3C6" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignaturePpc64Be, .guid = "F5E2C20C-45B2-4FFA-BCE9-2A60737E1AAF" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignaturePpc64Le, .guid = "1B31B5AA-ADD9-463A-B2ED-BD467FC857E7" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignatureRiscv32, .guid = "3A112A75-8729-4380-B4CF-764D79934448" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignatureRiscv64, .guid = "EFE0F087-EA8D-4469-821A-4C2A96A8386A" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignatureS390, .guid = "3482388E-4254-435A-A241-766A065F9960" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignatureS390x, .guid = "C80187A5-73A3-491A-901A-017C3FA953E9" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignatureTileGx, .guid = "B3671439-97B0-4A53-90F7-2D5A8F3AD47B" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignatureX64, .guid = "41092B05-9FC8-4523-994F-2DEF0408B176" },
        PairHuman{ .type = PartitionType.LinuxRootVeritySignatureX86_64, .guid = "5996FC05-109C-48DE-808B-23FA0830B676" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignatureAlpha, .guid = "5C6E1C76-076A-457A-A0FE-F3B4CD21CE6E" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignatureArc, .guid = "94F9A9A1-9971-427A-A400-50CB297F0F35" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignatureArm, .guid = "D7FF812F-37D1-4902-A810-D76BA57B975A" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignatureAarch64, .guid = "C23CE4FF-44BD-4B00-B2D4-B41B3419E02A" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignatureIA64, .guid = "8DE58BC2-2A43-460D-B14E-A76E4A17B47F" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignatureLoongArch64, .guid = "B024F315-D330-444C-8461-44BBDE524E99" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignatureMipsel, .guid = "3E23CA0B-A4BC-4B4E-8087-5AB6A26AA8A9" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignatureMips64el, .guid = "F2C2C7EE-ADCC-4351-B5C6-EE9816B66E16" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignaturePaRisc, .guid = "450DD7D1-3224-45EC-9CF2-A43A346D71EE" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignaturePpc32, .guid = "C8BFBD1E-268E-4521-8BBA-BF314C399557" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignaturePpc64Be, .guid = "0B888863-D7F8-4D9E-9766-239FCE4D58AF" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignaturePpc64Le, .guid = "7007891D-D371-4A80-86A4-5CB875B9302E" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignatureRiscv32, .guid = "C3836A13-3137-45BA-B583-B16C50FE5EB4" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignatureRiscv64, .guid = "D2F9000A-7A18-453F-B5CD-4D32F77A7B32" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignatureS390, .guid = "17440E4F-A8D0-467F-A46E-3912AE6EF2C5" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignatureS390x, .guid = "3F324816-667B-46AE-86EE-9B0C0C6C11B4" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignatureTileGx, .guid = "4EDE75E2-6CCC-4CC8-B9C7-70334B087510" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignatureX64, .guid = "E7BB33FB-06CF-4E81-8273-E543B413E2E2" },
        PairHuman{ .type = PartitionType.LinuxUsrVeritySignatureX86_64, .guid = "974A71C0-DE41-43C3-BE5D-5C5CCD1AD2C0" },
        PairHuman{ .type = PartitionType.LinuxExtendedBootLoader, .guid = "BC13C2FF-59E6-4262-A352-B275FD6F7172" },
        PairHuman{ .type = PartitionType.LinuxSwap, .guid = "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F" },
        PairHuman{ .type = PartitionType.LinuxLogicalVolumeManager, .guid = "E6D6D379-F507-44C2-A23C-238F2A3DF928" },
        PairHuman{ .type = PartitionType.LinuxHome, .guid = "933AC7E1-2EB4-4F13-B844-0E14E2AEF915" },
        PairHuman{ .type = PartitionType.LinuxServerData, .guid = "3B8F8425-20E0-4F3B-907F-1A25A76F98E8" },
        PairHuman{ .type = PartitionType.LinuxPerUserHome, .guid = "773F91EF-66D4-49B5-BD83-D683BF40AD16" },
        PairHuman{ .type = PartitionType.LinuxDmCrypt, .guid = "7FFEC5C9-2D00-49B7-8941-3EA10A5586B7" },
        PairHuman{ .type = PartitionType.LinuxLuks, .guid = "CA7D7CCB-63ED-4C53-861C-1742536059CC" },
        PairHuman{ .type = PartitionType.LinuxReserved, .guid = "8DA63339-0007-60C0-C436-083AC8230908" },
        PairHuman{ .type = PartitionType.FreebsdBoot, .guid = "83BD6B9D-7F41-11DC-BE0B-001560B84F0F" },
        PairHuman{ .type = PartitionType.FreebsdBsdDisklabel, .guid = "516E7CB4-6ECF-11D6-8FF8-00022D09712B" },
        PairHuman{ .type = PartitionType.FreebsdSwap, .guid = "516E7CB5-6ECF-11D6-8FF8-00022D09712B" },
        PairHuman{ .type = PartitionType.FreebsdUfs, .guid = "516E7CB6-6ECF-11D6-8FF8-00022D09712B" },
        PairHuman{ .type = PartitionType.FreebsdViniumVolumeManager, .guid = "516E7CB8-6ECF-11D6-8FF8-00022D09712B" },
        PairHuman{ .type = PartitionType.FreebsdZfs, .guid = "516E7CBA-6ECF-11D6-8FF8-00022D09712B" },
        PairHuman{ .type = PartitionType.FreebsdNandfs, .guid = "74BA7DD9-A689-11E1-BD04-00E081286ACF" },
        PairHuman{ .type = PartitionType.DarwinHfsPlus, .guid = "48465300-0000-11AA-AA11-00306543ECAC" },
        PairHuman{ .type = PartitionType.DarwinApfsContainer, .guid = "7C3457EF-0000-11AA-AA11-00306543ECAC" },
        PairHuman{ .type = PartitionType.DarwinUfsContainer, .guid = "55465300-0000-11AA-AA11-00306543ECAC" },
        PairHuman{ .type = PartitionType.DarwinZfs, .guid = "6A898CC3-1DD2-11B2-99A6-080020736631" },
        PairHuman{ .type = PartitionType.DarwinRaid, .guid = "52414944-0000-11AA-AA11-00306543ECAC" },
        PairHuman{ .type = PartitionType.DarwinRaidOffline, .guid = "52414944-5F4F-11AA-AA11-00306543ECAC" },
        PairHuman{ .type = PartitionType.DarwinBoot, .guid = "426F6F74-0000-11AA-AA11-00306543ECAC" },
        PairHuman{ .type = PartitionType.DarwinLabel, .guid = "4C616265-6C00-11AA-AA11-00306543ECAC" },
        PairHuman{ .type = PartitionType.DarwinTvRecovery, .guid = "5265636F-7665-11AA-AA11-00306543ECAC" },
        PairHuman{ .type = PartitionType.DarwinCoreStorageContainer, .guid = "53746F72-6167-11AA-AA11-00306543ECAC" },
        PairHuman{ .type = PartitionType.DarwinApfsPreboot, .guid = "69646961-6700-11AA-AA11-00306543ECAC" },
        PairHuman{ .type = PartitionType.DarwinApfsRecovery, .guid = "52637672-7900-11AA-AA11-00306543ECAC" },
        PairHuman{ .type = PartitionType.SolarisBoot, .guid = "6A82CB45-1DD2-11B2-99A6-080020736631" },
        PairHuman{ .type = PartitionType.SolarisRoot, .guid = "6A85CF4D-1DD2-11B2-99A6-080020736631" },
        PairHuman{ .type = PartitionType.SolarisSwap, .guid = "6A87C46F-1DD2-11B2-99A6-080020736631" },
        PairHuman{ .type = PartitionType.SolarisBackup, .guid = "6A8B642B-1DD2-11B2-99A6-080020736631" },
        PairHuman{ .type = PartitionType.SolarisUsr, .guid = "6A898CC3-1DD2-11B2-99A6-080020736631" },
        PairHuman{ .type = PartitionType.SolarisVar, .guid = "6A8EF2E9-1DD2-11B2-99A6-080020736631" },
        PairHuman{ .type = PartitionType.SolarisHome, .guid = "6A90BA39-1DD2-11B2-99A6-080020736631" },
        PairHuman{ .type = PartitionType.SolarisAlternateSector, .guid = "6A9283A5-1DD2-11B2-99A6-080020736631" },
        PairHuman{ .type = PartitionType.SolarisReserved, .guid = "6A945A3B-1DD2-11B2-99A6-080020736631" },
        PairHuman{ .type = PartitionType.SolarisReserved, .guid = "6A9630D1-1DD2-11B2-99A6-080020736631" },
        PairHuman{ .type = PartitionType.SolarisReserved, .guid = "6A980767-1DD2-11B2-99A6-080020736631" },
        PairHuman{ .type = PartitionType.SolarisReserved, .guid = "6A96237F-1DD2-11B2-99A6-080020736631" },
        PairHuman{ .type = PartitionType.SolarisReserved, .guid = "6A8D2AC7-1DD2-11B2-99A6-080020736631" },
        PairHuman{ .type = PartitionType.NetBsdSwap, .guid = "49F48D32-B10E-11DC-B99B-0019D1879648" },
        PairHuman{ .type = PartitionType.NetBsdFfs, .guid = "49F48D5A-B10E-11DC-B99B-0019D1879648" },
        PairHuman{ .type = PartitionType.NetBsdLfs, .guid = "49F48D82-B10E-11DC-B99B-0019D1879648" },
        PairHuman{ .type = PartitionType.NetBsdRaid, .guid = "49F48DAA-B10E-11DC-B99B-0019D1879648" },
        PairHuman{ .type = PartitionType.NetBsdConcatenated, .guid = "2DB519C4-B10F-11DC-B99B-0019D1879648" },
        PairHuman{ .type = PartitionType.NetBsdEncrypted, .guid = "2DB519EC-B10F-11DC-B99B-0019D1879648" },
        PairHuman{ .type = PartitionType.ChromeOsKernel, .guid = "FE3A2A5D-4F32-41A7-B725-ACCC3285A309" },
        PairHuman{ .type = PartitionType.ChromeOsRootfs, .guid = "3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC" },
        PairHuman{ .type = PartitionType.ChromeOsFirmware, .guid = "CAB6E88E-ABF3-4102-A07A-D4BB9BE3C1D3" },
        PairHuman{ .type = PartitionType.ChromeOsFutureUse, .guid = "2E0A753D-9E48-43B0-8337-B15192CB1B5E" },
        PairHuman{ .type = PartitionType.ChromeOsMiniOs, .guid = "09845860-705F-4BB5-B16C-8A8A099CAF52" },
        PairHuman{ .type = PartitionType.ChromeOsHibernate, .guid = "3F0F8318-F146-4E6B-8222-C28C8F02E0D5" },
        PairHuman{ .type = PartitionType.CoreOsUsr, .guid = "5DFBF5F4-2848-4BAC-AA5E-0D9A20B745A6" },
        PairHuman{ .type = PartitionType.CoreOsResizableRootfs, .guid = "3884DD41-8582-4404-B9A8-E9B84F2DF50E" },
        PairHuman{ .type = PartitionType.CoreOsOemCustomizations, .guid = "C95DC21A-DF0E-4340-8D7B-26CBFA9A03E0" },
        PairHuman{ .type = PartitionType.CoreOsRootRaid, .guid = "BE9067B9-EA49-4F15-B4F6-F36F8C9E1818" },
        PairHuman{ .type = PartitionType.HaikuBfs, .guid = "42465331-3BA3-10F1-802A-4861696B7521" },
        PairHuman{ .type = PartitionType.MidnightBsdBoot, .guid = "85D5E45E-237C-11E1-B4B3-E89A8F7FC3A7" },
        PairHuman{ .type = PartitionType.MidnightBsdData, .guid = "85D5E45A-237C-11E1-B4B3-E89A8F7FC3A7" },
        PairHuman{ .type = PartitionType.MidnightBsdSwap, .guid = "85D5E45B-237C-11E1-B4B3-E89A8F7FC3A7" },
        PairHuman{ .type = PartitionType.MidnightBsdUfs, .guid = "0394EF8B-237E-11E1-B4B3-E89A8F7FC3A7" },
        PairHuman{ .type = PartitionType.MidnightBsdViniumVolumeManager, .guid = "85D5E45C-237C-11E1-B4B3-E89A8F7FC3A7" },
        PairHuman{ .type = PartitionType.MidnightBsdZfs, .guid = "85D5E45D-237C-11E1-B4B3-E89A8F7FC3A7" },
        PairHuman{ .type = PartitionType.CephJournal, .guid = "45B0969E-9B03-4F30-B4C6-B4B80CEFF106" },
        PairHuman{ .type = PartitionType.CephDmCryptJournal, .guid = "45B0969E-9B03-4F30-B4C6-5EC00CEFF106" },
        PairHuman{ .type = PartitionType.CephOsd, .guid = "4FBD7E29-9D25-41B8-AFD0-062C0CEFF05D" },
        PairHuman{ .type = PartitionType.CephDmCryptOsd, .guid = "4FBD7E29-9D25-41B8-AFD0-5EC00CEFF05D" },
        PairHuman{ .type = PartitionType.CephDiskInCreation, .guid = "89C57F98-2FE5-4DC0-89C1-F3AD0CEFF2BE" },
        PairHuman{ .type = PartitionType.CephDmCryptDiskInCreation, .guid = "89C57F98-2FE5-4DC0-89C1-5EC00CEFF2BE" },
        PairHuman{ .type = PartitionType.CephBlock, .guid = "CAFECAFE-9B03-4F30-B4C6-B4B80CEFF106" },
        PairHuman{ .type = PartitionType.CephBlockDb, .guid = "30CD0809-C2B2-499C-8879-2D6B78529876" },
        PairHuman{ .type = PartitionType.CephBlockWriteAheadLog, .guid = "5CE17FCE-4087-4169-B7FF-056CC58473F9" },
        PairHuman{ .type = PartitionType.CephLockbox, .guid = "FB3AABF9-D25F-47CC-BF5E-721D1816496B" },
        PairHuman{ .type = PartitionType.CephMultipathOsd, .guid = "4FBD7E29-8AE0-4982-BF9D-5A8D867AF560" },
        PairHuman{ .type = PartitionType.CephMultipathJournal, .guid = "45B0969E-8AE0-4982-BF9D-5A8D867AF560" },
        PairHuman{ .type = PartitionType.CephMultipathBlockOne, .guid = "CAFECAFE-8AE0-4982-BF9D-5A8D867AF560" },
        PairHuman{ .type = PartitionType.CephMultipathBlockTwo, .guid = "7F4A666A-16F3-47A2-8445-152EF4D03F6C" },
        PairHuman{ .type = PartitionType.CephMultipathBlockDb, .guid = "EC6D6385-E346-45DC-BE91-DA2A7C8B3261" },
        PairHuman{ .type = PartitionType.CephMultipathBlockWriteAheadLog, .guid = "01B41E1B-002A-453C-9F17-88793989FF8F" },
        PairHuman{ .type = PartitionType.CephDmCryptBlock, .guid = "CAFECAFE-9B03-4F30-B4C6-5EC00CEFF106" },
        PairHuman{ .type = PartitionType.CephDmCryptBlockDb, .guid = "93B0052D-02D9-4D8A-A43B-33A3EE4DFBC3" },
        PairHuman{ .type = PartitionType.CephDmCryptBlockWriteAheadLog, .guid = "306E8683-4FE2-4330-B7C0-00A917C16966" },
        PairHuman{ .type = PartitionType.CephDmCryptLuksJournal, .guid = "45B0969E-9B03-4F30-B4C6-35865CEFF106" },
        PairHuman{ .type = PartitionType.CephDmCryptLuksBlock, .guid = "CAFECAFE-9B03-4F30-B4C6-35865CEFF106" },
        PairHuman{ .type = PartitionType.CephDmCryptLuksBlockDb, .guid = "166418DA-C469-4022-ADF4-B30AFD37F176" },
        PairHuman{ .type = PartitionType.CephDmCryptLuksBlockWriteAheadLog, .guid = "86A32090-3647-40B9-BBBD-38D8C573AA86" },
        PairHuman{ .type = PartitionType.CephDmCryptLuksOsd, .guid = "4FBD7E29-9D25-41B8-AFD0-35865CEFF05D" },
        PairHuman{ .type = PartitionType.OpenBsdData, .guid = "824CC7A0-36A8-11E3-890A-952519AD3F61" },
        PairHuman{ .type = PartitionType.QnxPowerSafeFileSystem, .guid = "CEF5A9AD-73BC-4601-89F3-CDEEEEE321A1" },
        PairHuman{ .type = PartitionType.Plan9, .guid = "C91818F9-8025-47AF-89D2-F030D7000C2C" },
        PairHuman{ .type = PartitionType.VmwareEsxVmkCore, .guid = "9D275380-40AD-11DB-BF97-000C2911D1B8" },
        PairHuman{ .type = PartitionType.VmwareEsxVmfs, .guid = "AA31E02A-400F-11DB-9590-000C2911D1B8" },
        PairHuman{ .type = PartitionType.VmwareEsxReserved, .guid = "9198EFFC-31C0-11DB-8F78-000C2911D1B8" },
        PairHuman{ .type = PartitionType.AndroidIaBootloader, .guid = "2568845D-2332-4675-BC39-8FA5A4748D15" },
        PairHuman{ .type = PartitionType.AndroidIaBootloader2, .guid = "114EAFFE-1552-4022-B26E-9B053604CF84" },
        PairHuman{ .type = PartitionType.AndroidIaBoot, .guid = "49A4D17F-93A3-45C1-A0DE-F50B2EBE2599" },
        PairHuman{ .type = PartitionType.AndroidIaRecovery, .guid = "4177C722-9E92-4AAB-8644-43502BFD5506" },
        PairHuman{ .type = PartitionType.AndroidIaMisc, .guid = "EF32A33B-A409-486C-9141-9FFB711F6266" },
        PairHuman{ .type = PartitionType.AndroidIaMetadata, .guid = "20AC26BE-20B7-11E3-84C5-6CFDB94711E9" },
        PairHuman{ .type = PartitionType.AndroidIaSystem, .guid = "38F428E6-D326-425D-9140-6E0EA133647C" },
        PairHuman{ .type = PartitionType.AndroidIaCache, .guid = "A893EF21-E428-470A-9E55-0668FD91A2D9" },
        PairHuman{ .type = PartitionType.AndroidIaData, .guid = "DC76DDA9-5AC1-491C-AF42-A82591580C0D" },
        PairHuman{ .type = PartitionType.AndroidIaPersistent, .guid = "EBC597D0-2053-4B15-8B64-E0AAC75F4DB1" },
        PairHuman{ .type = PartitionType.AndroidIaVendor, .guid = "C5A0AEEC-13EA-11E5-A1B1-001E67CA0C3C" },
        PairHuman{ .type = PartitionType.AndroidIaConfig, .guid = "BD59408B-4514-490D-BF12-9878D963F378" },
        PairHuman{ .type = PartitionType.AndroidIaFactory, .guid = "8F68CC74-C5E5-48DA-BE91-A0C8C15E9C80" },
        PairHuman{ .type = PartitionType.AndroidIaFactoryAlt, .guid = "9FDAA6EF-4B3F-40D2-BA8D-BFF16BFB887B" },
        PairHuman{ .type = PartitionType.AndroidIaFastboot, .guid = "767941D0-2085-11E3-AD3B-6CFDB94711E9" },
        PairHuman{ .type = PartitionType.AndroidIaOem, .guid = "AC6D7924-EB71-4DF8-B48D-E267B27148FF" },
        PairHuman{ .type = PartitionType.AndroidMeta, .guid = "19A710A2-B3CA-11E4-B026-10604B889DCF" },
        PairHuman{ .type = PartitionType.AndroidExt, .guid = "193D1EA4-B3CA-11E4-B075-10604B889DCF" },
        PairHuman{ .type = PartitionType.OnieBoot, .guid = "7412F7D5-A156-4B13-81DC-867174929325" },
        PairHuman{ .type = PartitionType.OnieConfig, .guid = "D4E6E2CD-4469-46F3-B5CB-1BFF57AFC149" },
        PairHuman{ .type = PartitionType.PowerPcPrepBoot, .guid = "9E1A2D38-C612-4316-AA26-8B49521E5A8B" },
        PairHuman{ .type = PartitionType.FreedesktopSharedBootLoaderConfiguration, .guid = "BC13C2FF-59E6-4262-A352-B275FD6F7172" },
        PairHuman{ .type = PartitionType.AtariTosBasicData, .guid = "734E5AFE-F61A-11E6-BC64-92361F002671" },
        PairHuman{ .type = PartitionType.VeraCryptEncryptedData, .guid = "8C8F8EFF-AC95-4770-814A-21994F2DBC8F" },
        PairHuman{ .type = PartitionType.Os2ArcaOsType1, .guid = "90B6FF38-B98F-4358-A21F-48F35B4A8AD3" },
        PairHuman{ .type = PartitionType.SpdkBlockDevice, .guid = "7C5222BD-8F5D-4087-9C00-BF9843C7B58C" },
        PairHuman{ .type = PartitionType.BareboxState, .guid = "4778ED65-BF42-45FA-9C5B-287A1DC4AAB1" },
        PairHuman{ .type = PartitionType.UbootEnvironment, .guid = "3DE21764-95BD-54BD-A5C3-4ABE786F38A8" },
        PairHuman{ .type = PartitionType.SoftRaidStatus, .guid = "B6FA30DA-92D2-4A9A-96F1-871EC6486200" },
        PairHuman{ .type = PartitionType.SoftRaidScratch, .guid = "2E313465-19B9-463F-8126-8A7993773801" },
        PairHuman{ .type = PartitionType.SoftRaidVolume, .guid = "FA709C7E-65B1-4593-BFD5-E71D61DE9B02" },
        PairHuman{ .type = PartitionType.SoftRaidCache, .guid = "BBBA6DF5-F46F-4A89-8F59-8765B2727503" },
        PairHuman{ .type = PartitionType.FuchsiaBootloader, .guid = "FE8A2634-5E2E-46BA-99E3-3A192091A350" },
        PairHuman{ .type = PartitionType.FuchsiaEncryptedSystemData, .guid = "D9FD4535-106C-4CEC-8D37-DFC020CA87CB" },
        PairHuman{ .type = PartitionType.FuchsiaBootloaderData, .guid = "A409E16B-78AA-4ACC-995C-302352621A41" },
        PairHuman{ .type = PartitionType.FuchsiaReadOnlySystemData, .guid = "F95D940E-CABA-4578-9B93-BB6C90F29D3E" },
        PairHuman{ .type = PartitionType.FuchsiaReadOnlyBootloaderData, .guid = "10B8DBAA-D2BF-42A9-98C6-A7C5DB3701E7" },
        PairHuman{ .type = PartitionType.FuchsiaVolumeManager, .guid = "49FD7CB8-DF15-4E73-B9D9-992070127F0F" },
        PairHuman{ .type = PartitionType.FuchsiaVerifiedBootMetadata, .guid = "421A8BFC-85D9-4D85-ACDA-B64EEC0133E9" },
        PairHuman{ .type = PartitionType.FuchsiaZirconBootImage, .guid = "9B37FFF6-2E58-466A-983A-F7926D0B04E0" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyEsp, .guid = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" },
        PairHuman{ .type = PartitionType.FuchsiaLegacySystem, .guid = "606B000B-B7C7-4653-A7D5-B737332C899D" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyData, .guid = "08185F0C-892D-428A-A789-DBEEC8F55E6A" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyInstall, .guid = "48435546-4953-2041-494E-5354414C4C52" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyBlob, .guid = "2967380E-134C-4CBB-B6DA-17E7CE1CA45D" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyFvm, .guid = "41D0E340-57E3-954E-8C1E-17ECAC44CFF5" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyZirconBootImageA, .guid = "DE30CC86-1F4A-4A31-93C4-66F147D33E05" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyZirconBootImageB, .guid = "23CC04DF-C278-4CE7-8471-897D1A4BCDF7" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyZirconBootImageR, .guid = "A0E5CF57-2DEF-46BE-A80C-A2067C37CD49" },
        PairHuman{ .type = PartitionType.FuchsiaLegacySysConfig, .guid = "4E5E989E-4C86-11E8-A15B-480FCF35F8E6" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyFactoryConfig, .guid = "5A3A90BE-4C86-11E8-A15B-480FCF35F8E6" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyBootloader, .guid = "5ECE94FE-4C86-11E8-A15B-480FCF35F8E6" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyGuidTest, .guid = "8B94D043-30BE-4871-9DFA-D69556E8C1F3" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyVerifiedBootMetadataA, .guid = "A13B4D9A-EC5F-11E8-97D8-6C3BE52705BF" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyVerifiedBootMetadataB, .guid = "A288ABF2-EC5F-11E8-97D8-6C3BE52705BF" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyVerifiedBootMetadataR, .guid = "6A2460C3-CD11-4E8B-80A8-12CCE268ED0A" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyMisc, .guid = "1D75395D-F2C6-476B-A8B7-45CC1C97B476" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyEmmcBoot1, .guid = "900B0FC5-90CD-4D4F-84F9-9F8ED579DB88" },
        PairHuman{ .type = PartitionType.FuchsiaLegacyEmmcBoot2, .guid = "B2B2E8D1-7C10-4EBC-A2D0-4614568260AD" },
    };

    var result: []const PairMachine = &.{};
    for (known) |part| {
        const guid = guidFromString(part.guid) catch @compileError(
            std.fmt.comptimePrint("invalid guid \"{s}\"", .{part.guid}),
        );
        result = result ++ [_]PairMachine{.{ .type = part.type, .guid = guid }};
    }

    break :b result;
};

pub const PartitionType = enum {
    UnusedEntry,
    MbrPartitionScheme,
    EfiSystem,
    BiosBoot,
    IntelFastFlash,
    SonyBoot,
    LenovoBoot,
    WindowsMicrosoftReserved,
    WindowsBasicData,
    WindowsLogicalDiskManagerMetadata,
    WindowsLogicalDiskManagerData,
    WindowsWindowsRecoveryEnvironment,
    WindowsIbmGeneralParallelFileSystem,
    WindowsStorageSpaces,
    WindowsStorageReplica,
    HpUxData,
    HpUxService,
    LinuxFilesystemData,
    LinuxRaid,
    LinuxRootAlpha,
    LinuxRootArc,
    LinuxRootArm,
    LinuxRootAarch64,
    LinuxRootIA64,
    LinuxRootLoongArch64,
    LinuxRootMipsel,
    LinuxRootMips64el,
    LinuxRootPaRisc,
    LinuxRootPpc32,
    LinuxRootPpc64Be,
    LinuxRootPpc64Le,
    LinuxRootRiscv32,
    LinuxRootRiscv64,
    LinuxRootS390,
    LinuxRootS390x,
    LinuxRootTileGx,
    LinuxRootX64,
    LinuxRootX86_64,
    LinuxUsrAlpha,
    LinuxUsrArc,
    LinuxUsrArm,
    LinuxUsrAarch64,
    LinuxUsrIA64,
    LinuxUsrLoongArch64,
    LinuxUsrMipsel,
    LinuxUsrMips64el,
    LinuxUsrPaRisc,
    LinuxUsrPpc32,
    LinuxUsrPpc64Be,
    LinuxUsrPpc64Le,
    LinuxUsrRiscv32,
    LinuxUsrRiscv64,
    LinuxUsrS390,
    LinuxUsrS390x,
    LinuxUsrTileGx,
    LinuxUsrX64,
    LinuxUsrX86_64,
    LinuxRootVerityAlpha,
    LinuxRootVerityArc,
    LinuxRootVerityArm,
    LinuxRootVerityAarch64,
    LinuxRootVerityIA64,
    LinuxRootVerityLoongArch64,
    LinuxRootVerityMipsel,
    LinuxRootVerityMips64el,
    LinuxRootVerityPaRisc,
    LinuxRootVerityPpc32,
    LinuxRootVerityPpc64Be,
    LinuxRootVerityPpc64Le,
    LinuxRootVerityRiscv32,
    LinuxRootVerityRiscv64,
    LinuxRootVerityS390,
    LinuxRootVerityS390x,
    LinuxRootVerityTileGx,
    LinuxRootVerityX64,
    LinuxRootVerityX86_64,
    LinuxUsrVerityAlpha,
    LinuxUsrVerityArc,
    LinuxUsrVerityArm,
    LinuxUsrVerityAarch64,
    LinuxUsrVerityIA64,
    LinuxUsrVerityLoongArch64,
    LinuxUsrVerityMipsel,
    LinuxUsrVerityMips64el,
    LinuxUsrVerityPaRisc,
    LinuxUsrVerityPpc32,
    LinuxUsrVerityPpc64Be,
    LinuxUsrVerityPpc64Le,
    LinuxUsrVerityRiscv32,
    LinuxUsrVerityRiscv64,
    LinuxUsrVerityS390,
    LinuxUsrVerityS390x,
    LinuxUsrVerityTileGx,
    LinuxUsrVerityX64,
    LinuxUsrVerityX86_64,
    LinuxRootVeritySignatureAlpha,
    LinuxRootVeritySignatureArc,
    LinuxRootVeritySignatureArm,
    LinuxRootVeritySignatureAarch64,
    LinuxRootVeritySignatureIA64,
    LinuxRootVeritySignatureLoongArch64,
    LinuxRootVeritySignatureMipsel,
    LinuxRootVeritySignatureMips64el,
    LinuxRootVeritySignaturePaRisc,
    LinuxRootVeritySignaturePpc32,
    LinuxRootVeritySignaturePpc64Be,
    LinuxRootVeritySignaturePpc64Le,
    LinuxRootVeritySignatureRiscv32,
    LinuxRootVeritySignatureRiscv64,
    LinuxRootVeritySignatureS390,
    LinuxRootVeritySignatureS390x,
    LinuxRootVeritySignatureTileGx,
    LinuxRootVeritySignatureX64,
    LinuxRootVeritySignatureX86_64,
    LinuxUsrVeritySignatureAlpha,
    LinuxUsrVeritySignatureArc,
    LinuxUsrVeritySignatureArm,
    LinuxUsrVeritySignatureAarch64,
    LinuxUsrVeritySignatureIA64,
    LinuxUsrVeritySignatureLoongArch64,
    LinuxUsrVeritySignatureMipsel,
    LinuxUsrVeritySignatureMips64el,
    LinuxUsrVeritySignaturePaRisc,
    LinuxUsrVeritySignaturePpc32,
    LinuxUsrVeritySignaturePpc64Be,
    LinuxUsrVeritySignaturePpc64Le,
    LinuxUsrVeritySignatureRiscv32,
    LinuxUsrVeritySignatureRiscv64,
    LinuxUsrVeritySignatureS390,
    LinuxUsrVeritySignatureS390x,
    LinuxUsrVeritySignatureTileGx,
    LinuxUsrVeritySignatureX64,
    LinuxUsrVeritySignatureX86_64,
    LinuxExtendedBootLoader,
    LinuxSwap,
    LinuxLogicalVolumeManager,
    LinuxHome,
    LinuxServerData,
    LinuxPerUserHome,
    LinuxDmCrypt,
    LinuxLuks,
    LinuxReserved,
    FreebsdBoot,
    FreebsdBsdDisklabel,
    FreebsdSwap,
    FreebsdUfs,
    FreebsdViniumVolumeManager,
    FreebsdZfs,
    FreebsdNandfs,
    DarwinHfsPlus,
    DarwinApfsContainer,
    DarwinUfsContainer,
    DarwinZfs,
    DarwinRaid,
    DarwinRaidOffline,
    DarwinBoot,
    DarwinLabel,
    DarwinTvRecovery,
    DarwinCoreStorageContainer,
    DarwinApfsPreboot,
    DarwinApfsRecovery,
    SolarisBoot,
    SolarisRoot,
    SolarisSwap,
    SolarisBackup,
    SolarisUsr,
    SolarisVar,
    SolarisHome,
    SolarisAlternateSector,
    SolarisReserved,
    NetBsdSwap,
    NetBsdFfs,
    NetBsdLfs,
    NetBsdRaid,
    NetBsdConcatenated,
    NetBsdEncrypted,
    ChromeOsKernel,
    ChromeOsRootfs,
    ChromeOsFirmware,
    ChromeOsFutureUse,
    ChromeOsMiniOs,
    ChromeOsHibernate,
    CoreOsUsr,
    CoreOsResizableRootfs,
    CoreOsOemCustomizations,
    CoreOsRootRaid,
    HaikuBfs,
    MidnightBsdBoot,
    MidnightBsdData,
    MidnightBsdSwap,
    MidnightBsdUfs,
    MidnightBsdViniumVolumeManager,
    MidnightBsdZfs,
    CephJournal,
    CephDmCryptJournal,
    CephOsd,
    CephDmCryptOsd,
    CephDiskInCreation,
    CephDmCryptDiskInCreation,
    CephBlock,
    CephBlockDb,
    CephBlockWriteAheadLog,
    CephLockbox,
    CephMultipathOsd,
    CephMultipathJournal,
    CephMultipathBlockOne,
    CephMultipathBlockTwo,
    CephMultipathBlockDb,
    CephMultipathBlockWriteAheadLog,
    CephDmCryptBlock,
    CephDmCryptBlockDb,
    CephDmCryptBlockWriteAheadLog,
    CephDmCryptLuksJournal,
    CephDmCryptLuksBlock,
    CephDmCryptLuksBlockDb,
    CephDmCryptLuksBlockWriteAheadLog,
    CephDmCryptLuksOsd,
    OpenBsdData,
    QnxPowerSafeFileSystem,
    Plan9,
    VmwareEsxVmkCore,
    VmwareEsxVmfs,
    VmwareEsxReserved,
    AndroidIaBootloader,
    AndroidIaBootloader2,
    AndroidIaBoot,
    AndroidIaRecovery,
    AndroidIaMisc,
    AndroidIaMetadata,
    AndroidIaSystem,
    AndroidIaCache,
    AndroidIaData,
    AndroidIaPersistent,
    AndroidIaVendor,
    AndroidIaConfig,
    AndroidIaFactory,
    AndroidIaFactoryAlt,
    AndroidIaFastboot,
    AndroidIaOem,
    AndroidMeta,
    AndroidExt,
    OnieBoot,
    OnieConfig,
    PowerPcPrepBoot,
    FreedesktopSharedBootLoaderConfiguration,
    AtariTosBasicData,
    VeraCryptEncryptedData,
    Os2ArcaOsType1,
    SpdkBlockDevice,
    BareboxState,
    UbootEnvironment,
    SoftRaidStatus,
    SoftRaidScratch,
    SoftRaidVolume,
    SoftRaidCache,
    FuchsiaBootloader,
    FuchsiaEncryptedSystemData,
    FuchsiaBootloaderData,
    FuchsiaReadOnlySystemData,
    FuchsiaReadOnlyBootloaderData,
    FuchsiaVolumeManager,
    FuchsiaVerifiedBootMetadata,
    FuchsiaZirconBootImage,
    FuchsiaLegacyEsp,
    FuchsiaLegacySystem,
    FuchsiaLegacyData,
    FuchsiaLegacyInstall,
    FuchsiaLegacyBlob,
    FuchsiaLegacyFvm,
    FuchsiaLegacyZirconBootImageA,
    FuchsiaLegacyZirconBootImageB,
    FuchsiaLegacyZirconBootImageR,
    FuchsiaLegacySysConfig,
    FuchsiaLegacyFactoryConfig,
    FuchsiaLegacyBootloader,
    FuchsiaLegacyGuidTest,
    FuchsiaLegacyVerifiedBootMetadataA,
    FuchsiaLegacyVerifiedBootMetadataB,
    FuchsiaLegacyVerifiedBootMetadataR,
    FuchsiaLegacyMisc,
    FuchsiaLegacyEmmcBoot1,
    FuchsiaLegacyEmmcBoot2,

    pub fn fromGuid(guid: std.os.uefi.Guid) ?@This() {
        inline for (known_partition_guids) |part| {
            if (part.guid.eql(guid)) {
                return part.type;
            }
        }
        return null;
    }
};

const PartitionRecord = extern struct {
    partition_type: [16]u8,
    partition_guid: [16]u8,
    first_lba: u64,
    last_lba_inclusive: u64,
    attribute_flags: u64,
    partition_name: [72]u8,

    /// Caller is responsible for returned slice.
    pub fn name(self: *const @This(), allocator: mem.Allocator) ![]const u8 {
        const byte_count = @sizeOf(@TypeOf(self.partition_name)) / @sizeOf(u16);
        var name_utf16le_bytes: [byte_count]u16 = @bitCast(self.partition_name);
        var name_utf8_bytes: [byte_count]u8 = undefined;
        const end = try std.unicode.utf16leToUtf8(&name_utf8_bytes, &name_utf16le_bytes);
        return try allocator.dupe(u8, std.mem.trimRight(u8, name_utf8_bytes[0..end], &.{0}));
    }

    pub fn partType(self: *const @This()) ?PartitionType {
        const guid: std.os.uefi.Guid = @bitCast(self.partition_type);
        return PartitionType.fromGuid(guid);
    }
};

const Header = extern struct {
    signature: [8]u8,
    revision: u32,
    header_size: u32,
    header_crc32: u32,
    reserved: u32,
    current_lba: u64,
    backup_lba: u64,
    first_usable_lba: u64,
    last_usable_lba: u64,
    disk_guid: [16]u8,
    starting_partition_entry_lba: u64,
    num_partition_entries: u32,
    partition_entry_size: u32,
    partition_entries_crc32: u32,
    unused_reserved: [420]u8,
};

/// A read-only GUID partition table
// TODO(jared):
// - Parse recovery header
// - Verify partition CRC
const Gpt = @This();

pub const Error = error{
    NoGptFound,
    InvalidHeaderSize,
    InvalidPartitionSize,
    UnknownPartitionEntrySize,
    MissingMagicNumber,
    HeaderCrcFail,
};

const magic = "EFI PART";

sector_size: u16,
source: *io.StreamSource,
header: Header,

/// Caller is responsible for source.
pub fn init(source: *io.StreamSource) !Gpt {
    for ([_]u16{ 512, 1024, 2048, 4096 }) |sector_size| {
        try source.seekTo(sector_size * 1); // LBA1
        var header_bytes: [@sizeOf(Header)]u8 = undefined;
        const bytes_read = try source.reader().readAll(&header_bytes);
        if (bytes_read != @sizeOf(Header)) {
            return Error.InvalidHeaderSize;
        }
        const aligned_buf = @as([]align(@alignOf(Header)) u8, @alignCast(&header_bytes));

        const header: *Header = @ptrCast(aligned_buf);
        if (!mem.eql(u8, &header.signature, magic)) {
            continue;
        }

        const partition_entry_size = mem.littleToNative(@TypeOf(header.partition_entry_size), header.partition_entry_size);
        if (partition_entry_size != @sizeOf(PartitionRecord)) {
            return Error.UnknownPartitionEntrySize;
        }

        const calculated_crc = b: {
            // The CRC calculation is done without the unused bytes.
            var zeroed_crc_header: [@offsetOf(Header, "unused_reserved")]u8 = undefined;
            @memcpy(&zeroed_crc_header, header_bytes[0..@offsetOf(Header, "unused_reserved")]);

            var i: u8 = 0;
            while (i < @sizeOf(@TypeOf(header.header_crc32))) : (i += 1) {
                zeroed_crc_header[@offsetOf(Header, "header_crc32") + i] = 0;
            }

            break :b std.hash.crc.Crc32.hash(&zeroed_crc_header);
        };
        if (calculated_crc != mem.littleToNative(
            @TypeOf(header.header_crc32),
            header.header_crc32,
        )) {
            return Error.HeaderCrcFail;
        }

        return .{
            .sector_size = sector_size,
            .source = source,
            .header = header.*,
        };
    }

    return Error.NoGptFound;
}

/// Caller is responsible for returned slice.
pub fn partitions(self: *Gpt, allocator: std.mem.Allocator) ![]PartitionRecord {
    var p = std.ArrayList(PartitionRecord).init(allocator);
    errdefer p.deinit();

    var partition_offset = mem.littleToNative(@TypeOf(self.header.starting_partition_entry_lba), self.header.starting_partition_entry_lba) * self.sector_size;
    const partition_end =
        mem.littleToNative(@TypeOf(self.header.num_partition_entries), self.header.num_partition_entries) *
        @sizeOf(PartitionRecord) +
        partition_offset;

    while (partition_offset <= partition_end) : (partition_offset += @sizeOf(PartitionRecord)) {
        try self.source.seekTo(partition_offset);

        var part_bytes: [@sizeOf(PartitionRecord)]u8 = undefined;
        const bytes_read = try self.source.reader().readAll(&part_bytes);
        if (bytes_read != @sizeOf(PartitionRecord)) {
            return Error.InvalidPartitionSize;
        }
        const aligned_buf = @as([]align(@alignOf(PartitionRecord)) u8, @alignCast(&part_bytes));

        const part: *PartitionRecord = @ptrCast(aligned_buf);

        // UnusedEntry is an indication that there are no longer any valid
        // partitions at or beyond our current position.
        if (part.partType()) |part_type| {
            if (part_type == .UnusedEntry) {
                break;
            }
        }

        try p.append(part.*);
    }

    return p.toOwnedSlice();
}

test "guid parsing" {
    const got_guid = try guidFromString("C12A7328-F81F-11D2-BA4B-00A0C93EC93B");
    const bytes = [_]u8{ 0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b };
    const expected_guid: std.os.uefi.Guid = @bitCast(bytes);

    try std.testing.expect(expected_guid.eql(got_guid));

    const partition_type = PartitionType.fromGuid(got_guid).?;
    try std.testing.expectEqual(PartitionType.EfiSystem, partition_type);
}

test "gpt header struct sizes and offset" {
    try std.testing.expectEqual(512, @sizeOf(Header));
    try std.testing.expectEqual(128, @sizeOf(PartitionRecord));
    try std.testing.expectEqual(84, @offsetOf(Header, "partition_entry_size"));
}

test "gpt parsing" {
    const partition_table = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x00, 0xee, 0xff, 0xff, 0xff, 0x01, 0x00, 0x00, 0x00, 0xff, 0xff, 0x3f, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x55, 0xaa,
        0x45, 0x46, 0x49, 0x20, 0x50, 0x41, 0x52, 0x54, 0x00, 0x00, 0x01, 0x00, 0x5c, 0x00, 0x00, 0x00,
        0xfb, 0x5a, 0x6e, 0xac, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xff, 0xff, 0x3f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x22, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xde, 0xff, 0x3f, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe3, 0xdb, 0x21, 0xef, 0xdd, 0x06, 0x94, 0x4b,
        0xa1, 0x4d, 0xd8, 0x44, 0xa7, 0x25, 0x0a, 0x8a, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x81, 0x7b, 0x0b, 0xba, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b,
        0xe5, 0xec, 0x58, 0x10, 0xe3, 0x29, 0x08, 0x48, 0xbd, 0xbe, 0xf3, 0x95, 0xca, 0x2e, 0xba, 0x0f,
        0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x07, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x42, 0x00, 0x4f, 0x00, 0x4f, 0x00, 0x54, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xaf, 0x3d, 0xc6, 0x0f, 0x83, 0x84, 0x72, 0x47, 0x8e, 0x79, 0x3d, 0x69, 0xd8, 0x47, 0x7d, 0xe4,
        0xdb, 0xc2, 0xb6, 0x84, 0x9a, 0xeb, 0x24, 0x41, 0x90, 0xe8, 0xf8, 0x6f, 0x4b, 0x3c, 0x2a, 0x07,
        0x00, 0x08, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xf7, 0x3f, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x72, 0x00, 0x6f, 0x00, 0x6f, 0x00, 0x74, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };

    var source = io.StreamSource{ .const_buffer = io.fixedBufferStream(partition_table[0..]) };

    var disk = try Gpt.init(&source);

    try std.testing.expectEqual(@as(u16, 512), disk.sector_size);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xe3, 0xdb, 0x21, 0xef, 0xdd, 0x06, 0x94, 0x4b, 0xa1, 0x4d, 0xd8, 0x44, 0xa7, 0x25, 0x0a, 0x8a },
        &disk.header.disk_guid,
    );

    var all_partitions = try disk.partitions(std.testing.allocator);
    defer std.testing.allocator.free(all_partitions);

    try std.testing.expectEqual(@as(usize, 2), all_partitions.len);

    const name1 = try all_partitions[0].name(std.testing.allocator);
    defer std.testing.allocator.free(name1);
    try std.testing.expectEqualStrings("BOOT", name1);

    try std.testing.expectEqual(
        PartitionType.EfiSystem,
        all_partitions[0].partType() orelse @panic("couldn't get partition type"),
    );

    const name2 = try all_partitions[1].name(std.testing.allocator);
    defer std.testing.allocator.free(name2);
    try std.testing.expectEqualStrings("root", name2);

    try std.testing.expectEqual(
        PartitionType.LinuxFilesystemData,
        all_partitions[1].partType() orelse @panic("couldn't get partition type"),
    );
}
