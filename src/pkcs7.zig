const std = @import("std");
const asn1 = std.crypto.asn1;

const sequence_of_tag = asn1.Tag.universal(.sequence_of, true);
const sequence_tag = asn1.Tag.universal(.sequence, true);
const integer_tag = asn1.Tag.universal(.integer, false);
const printable_string_tag = asn1.Tag.universal(.string_printable, false);
const utf8_string_tag = asn1.Tag.universal(.string_utf8, false);
const octetstring_tag = asn1.Tag.universal(.octetstring, false);

const DigestAlgorithmIdentifier = struct {
    const Algorithm = enum {
        sha256,

        pub const oids = asn1.Oid.StaticMap(@This()).initComptime(.{
            .sha256 = "2.16.840.1.101.3.4.2.1",
        });
    };

    algorithm: Algorithm,

    // TODO(jared): make encoding this work OOTB
    parameters: struct {
        pub fn encodeDer(self: @This(), encoder: *asn1.der.Encoder) !void {
            _ = self;
            try encoder.any(null);
        }
    },
};

const SignatureAlgorithmIdentifier = struct {
    const Algorithm = enum {
        rsa,

        pub const oids = asn1.Oid.StaticMap(@This()).initComptime(.{
            .rsa = "1.2.840.113549.1.1.1",
        });
    };

    algorithm: Algorithm,

    // TODO(jared): make encoding this work OOTB
    parameters: struct {
        pub fn encodeDer(self: @This(), encoder: *asn1.der.Encoder) !void {
            _ = self;
            try encoder.any(null);
        }
    },
};

const ContentType = enum {
    signed_data,

    pub const oids = asn1.Oid.StaticMap(@This()).initComptime(.{
        .signed_data = "1.2.840.113549.1.7.2",
    });
};

const Content = union(ContentType) {
    const SignedData = struct {
        const DigestAlgorithms = struct {
            pub const asn1_tag = sequence_of_tag;

            inner: DigestAlgorithmIdentifier,
        };

        const EncapsulatedContentInfo = struct {
            const EncapsulatedContentType = enum {
                pkcs7,

                pub const oids = asn1.Oid.StaticMap(@This()).initComptime(.{
                    .pkcs7 = "1.2.840.113549.1.7.1",
                });
            };

            content_type: EncapsulatedContentType,
        };

        const SignerInfos = struct {
            const SignerInfo = struct {
                const IssuerAndSerialNumber = struct {
                    const Name = struct {
                        const RelativeDistinguishedName = struct {
                            const InnerName = struct {
                                const AttributeTypeAndValue = struct {
                                    type: asn1.Oid,
                                    value: []const u8,

                                    const common_name_oid = asn1.Oid.fromDotComptime("2.5.4.3");
                                    const organization_name_oid = asn1.Oid.fromDotComptime("2.5.4.10");

                                    pub fn encodeDer(self: @This(), encoder: *asn1.der.Encoder) !void {
                                        const tag = if (std.mem.eql(
                                            u8,
                                            self.type.encoded,
                                            common_name_oid.encoded,
                                        ) or std.mem.eql(
                                            u8,
                                            self.type.encoded,
                                            organization_name_oid.encoded,
                                        )) utf8_string_tag else printable_string_tag;

                                        try encoder.tagBytes(tag, self.value);
                                        try encoder.any(self.type);
                                    }
                                };

                                inner: AttributeTypeAndValue,
                            };

                            inner: []const InnerName,

                            pub fn encodeDer(self: @This(), encoder: *asn1.der.Encoder) !void {
                                for (self.inner) |name| {
                                    const start = encoder.buffer.data.len;
                                    try encoder.any(name);
                                    try encoder.length(encoder.buffer.data.len - start);
                                    try encoder.tag(sequence_of_tag);
                                }
                            }
                        };

                        relative_distinguished_name: RelativeDistinguishedName,
                    };

                    rdn_sequence: Name,
                    serial_number: []u8,

                    pub fn encodeDer(self: @This(), encoder: *asn1.der.Encoder) !void {
                        const start = encoder.buffer.data.len;

                        try encoder.tagBytes(integer_tag, self.serial_number);
                        try encoder.any(self.rdn_sequence);

                        try encoder.length(encoder.buffer.data.len - start);
                        try encoder.tag(sequence_tag);
                    }
                };

                const SignatureValue = struct {
                    data: []const u8,

                    pub fn encodeDer(self: @This(), encoder: *asn1.der.Encoder) !void {
                        try encoder.tagBytes(octetstring_tag, self.data);
                    }
                };

                version: u8,
                issuer_and_serial_number: IssuerAndSerialNumber,
                digest_algorithm: DigestAlgorithmIdentifier,
                signature_algorithm: SignatureAlgorithmIdentifier,
                signature: SignatureValue,
            };

            inner: []const SignerInfo,

            pub fn encodeDer(self: @This(), encoder: *asn1.der.Encoder) !void {
                const start = encoder.buffer.data.len;

                for (self.inner) |name| {
                    try encoder.any(name);
                }

                try encoder.length(encoder.buffer.data.len - start);
                try encoder.tag(sequence_of_tag);
            }
        };

        version: u8,
        digest_algorithms: DigestAlgorithms,
        encapsulated_content_info: EncapsulatedContentInfo,
        signer_infos: SignerInfos,
    };

    signed_data: SignedData,

    pub fn encodeDer(self: @This(), encoder: *asn1.der.Encoder) !void {
        const start = encoder.buffer.data.len;

        switch (self) {
            inline else => |data| try encoder.any(data),
        }

        try encoder.length(encoder.buffer.data.len - start);
        try encoder.tag(asn1.FieldTag.initExplicit(0, .context_specific).toTag());
    }
};

content_type: ContentType,
content: Content,
