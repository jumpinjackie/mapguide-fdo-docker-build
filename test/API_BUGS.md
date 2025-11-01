# Known mapagent issues to fix

## GETSPATIALCONTEXTS

`ACTIVEONLY` should not be a required parameter (and default to `0` if not specified)

## SELECTAGGREGATES

When `FORMAT=application/json` the response is not a literal XML to JSON conversion

XML:

```xml
<?xml version="1.0" encoding="UTF-8"?><PropertySet><PropertyDefinitions><PropertyDefinition><Name>total</Name><Type>int64</Type></PropertyDefinition></PropertyDefinitions><Properties><PropertyCollection><Property><Name>total</Name><Value>9</Value></Property></PropertyCollection></Properties></PropertySet>
```

JSON:

```json
{
	"PropertySet": {
		"PropertyDefinitions": [
			{
				"PropertyDefinition": [
					{
						"Name": [
							"total"
						],
						"Type": [
							"int64"
						]
					}
				]
			}
		],
		"Properties": [
			{
				"PropertyDefinitions": [
					{
						"PropertyDefinition": [
							{
								"Name": [
									"total"
								],
								"Type": [
									"int64"
								]
							}
						]
					}
				]
			}
		]
	}
}
```

# GEO.*

`FORMAT` parameter checking should be case-insensitive

Bad/invalid `FORMAT` parameters not being checked

# GETMAPIMAGE

Validate required `FORMAT` parameter (ie. Throw if missing)