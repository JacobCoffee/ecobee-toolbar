"""Simulated ecobee for developing EcobeeBar without hardware.

Advertises a HomeKit thermostat (setup code 123-45-678) that mirrors the
characteristics a real ecobee exposes over HAP: thermostat service with fan
state, ecobee's vendor comfort-profile characteristics, and a remote
SmartSensor accessory. Current temperature drifts toward the setpoint so
HVAC activity and event notifications can be observed.

Add it to Apple Home (Home app → Add Accessory → More options, code
123-45-678) and it shows up in EcobeeBar alongside your real thermostats.
Remove it from the Home app when you're done.

    uv run --with HAP-python dev/fake_thermostat.py [--state PATH] [--port 51826]
"""

import argparse
import logging
import random
import uuid

from pyhap.accessory import Accessory, Bridge
from pyhap.accessory_driver import AccessoryDriver
from pyhap.characteristic import Characteristic
from pyhap.const import CATEGORY_THERMOSTAT

COMFORT_READ = uuid.UUID("B7DDB9A3-54BB-4572-91D2-F1F5B0510F8C")
COMFORT_WRITE = uuid.UUID("1B300BC2-CFFC-47FF-89F9-BD6CCF5F2853")


class Thermostat(Accessory):
    category = CATEGORY_THERMOSTAT

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        loader = self.driver.loader
        serv = loader.get_service("Thermostat")
        for name in ("CurrentRelativeHumidity", "CoolingThresholdTemperature", "HeatingThresholdTemperature",
                     "TargetFanState", "CurrentFanState"):
            serv.add_characteristic(loader.get_char(name))

        self.current = serv.configure_char("CurrentTemperature", value=21.0)
        self.target = serv.configure_char(
            "TargetTemperature", value=22.0,
            properties={"minValue": 7.2, "maxValue": 33.3, "minStep": 0.1},
        )
        self.heat = serv.configure_char(
            "HeatingThresholdTemperature", value=20.0,
            properties={"minValue": 7.2, "maxValue": 26.1, "minStep": 0.1},
        )
        self.cool = serv.configure_char(
            "CoolingThresholdTemperature", value=24.5,
            properties={"minValue": 18.3, "maxValue": 33.3, "minStep": 0.1},
        )
        self.mode = serv.configure_char("TargetHeatingCoolingState", value=1)
        self.activity = serv.configure_char("CurrentHeatingCoolingState", value=0)
        self.units = serv.configure_char("TemperatureDisplayUnits", value=1)
        self.humidity = serv.configure_char("CurrentRelativeHumidity", value=44)
        self.fan_target = serv.configure_char("TargetFanState", value=1)
        self.fan_current = serv.configure_char("CurrentFanState", value=1)

        self.comfort = Characteristic(
            "ComfortProfile", COMFORT_READ,
            {"Format": "uint8", "Permissions": ["pr", "ev"], "minValue": 0, "maxValue": 3},
        )
        self.comfort.value = 0
        self.comfort_set = Characteristic(
            "ComfortProfileSet", COMFORT_WRITE,
            {"Format": "uint8", "Permissions": ["pw"], "minValue": 0, "maxValue": 3},
        )
        self.comfort_set.setter_callback = lambda v: self.comfort.set_value(v)
        serv.add_characteristic(self.comfort, self.comfort_set)
        self.add_service(serv)

        for char in (self.target, self.heat, self.cool, self.mode, self.fan_target, self.units):
            char.setter_callback = self._logger(char.display_name)

    def _logger(self, name):
        def setter(value):
            logging.info("write %s = %s", name, value)
        return setter

    def _goal(self):
        mode = self.mode.value
        cur = self.current.value
        if mode == 1:
            return self.target.value, 1 if cur < self.target.value - 0.2 else 0
        if mode == 2:
            return self.target.value, 2 if cur > self.target.value + 0.2 else 0
        if mode == 3:
            if cur < self.heat.value - 0.2:
                return self.heat.value, 1
            if cur > self.cool.value + 0.2:
                return self.cool.value, 2
        return cur, 0

    @Accessory.run_at_interval(3)
    def run(self):
        goal, activity = self._goal()
        cur = self.current.value
        if activity:
            cur += max(-0.3, min(0.3, goal - cur))
        else:
            cur += random.uniform(-0.05, 0.05)
        self.current.set_value(round(cur, 1))
        if self.activity.value != activity:
            self.activity.set_value(activity)
        fan = 2 if activity or self.fan_target.value == 0 else 1
        if self.fan_current.value != fan:
            self.fan_current.set_value(fan)


class SmartSensor(Accessory):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.temp = self.add_preload_service("TemperatureSensor").configure_char("CurrentTemperature", value=20.4)
        self.occupied = self.add_preload_service("OccupancySensor").configure_char("OccupancyDetected", value=1)

    @Accessory.run_at_interval(10)
    def run(self):
        self.temp.set_value(round(self.temp.value + random.uniform(-0.1, 0.1), 1))
        if random.random() < 0.2:
            self.occupied.set_value(1 - self.occupied.value)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", default="fake_thermostat.state")
    parser.add_argument("--port", type=int, default=51826)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")

    driver = AccessoryDriver(port=args.port, persist_file=args.state, pincode=b"123-45-678")
    bridge = Bridge(driver, "Fake ecobee")
    bridge.category = CATEGORY_THERMOSTAT
    bridge.add_accessory(Thermostat(driver, "Main Floor"))
    bridge.add_accessory(SmartSensor(driver, "Bedroom"))
    driver.add_accessory(bridge)
    driver.start()


if __name__ == "__main__":
    main()
