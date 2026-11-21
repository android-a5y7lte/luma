# SPDX-License-Identifier: Apache-2.0
import hashlib
from pathlib import Path
import re
import tomllib
import unittest

DEVICE = Path(__file__).resolve().parents[1]
ROOT = DEVICE.parents[2]


def load(name):
    return tomllib.loads((DEVICE / name).read_text())


class SuryaProfile(unittest.TestCase):
    def test_bring_up_tier_and_family(self):
        device = load('device.toml')
        soc = tomllib.loads((ROOT / 'socs/qcom/sm7150/soc.toml').read_text())
        self.assertEqual(device['tier'], 'experimental')
        self.assertEqual(device['soc'], 'qcom/sm7150')
        self.assertEqual(soc['boot']['slots'], 'a-only')
        self.assertEqual(device['fastboot_product'], 'surya')

    def test_huaxing_device_tree(self):
        self.assertEqual(load('device.toml')['kernel']['dtb'],
                         'qcom/sm7150-xiaomi-surya-huaxing.dtb')

    def test_no_published_release_is_invented(self):
        device = load('device.toml')
        self.assertNotIn('releases', device)
        self.assertNotIn('kit', device)

    def test_dtbo_blanked_not_flashed_with_stock(self):
        boot = load('boot.toml')
        self.assertEqual(boot['dtbo']['policy'], 'blank')
        self.assertEqual(boot['dtbo']['partitions'], ['dtbo'])

    def test_install_guide_only_ram_boots(self):
        guide = (DEVICE / 'INSTALL.md').read_text()
        commands = re.findall(r'^fastboot .*$', guide, re.M)
        self.assertTrue(commands)
        for command in commands:
            self.assertNotRegex(command, r'\b(flash|erase|format)\b', command)

    def test_firmware_manifest_is_exact(self):
        device = load('device.toml')
        manifest = (DEVICE / 'firmware.manifest').read_bytes()
        self.assertEqual(hashlib.sha256(manifest).hexdigest(),
                         device['firmware']['manifest_sha256'])
        for name in (b'a615_zap.mbn', b'adsp.mbn', b'cdsp.mbn', b'modem.mbn',
                     b'wlanmdsp.mbn', b'venus.mbn', b'novatek_ts_huaxing_fw.bin'):
            self.assertIn(b'qcom/sm7150/xiaomi/surya/' + name, manifest)


if __name__ == '__main__':
    unittest.main()
