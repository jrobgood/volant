// oxlint-disable next/no-html-link-for-pages -- vinext 1.0.0-beta.5's next/link throws in the
// production build, leaving internal navigation dead. Plain anchors until fixed upstream.
import type { Metadata } from 'next';

import { adjacentDocs } from '../docs-nav';
import { DocFooterNav } from '@/components/doc-footer-nav';

export const metadata: Metadata = {
  title: 'The calculator — Volant docs',
  description:
    'Arithmetic, percentages, units, time zones, dates, colors and currency, answered as you type in the launcher.',
  alternates: { canonical: 'https://usevolant.com/docs/calculator' },
};

function Examples({ rows }: { rows: [string, string][] }) {
  return (
    <div className="docs-table-scroll">
      <table className="docs-table">
        <thead>
          <tr>
            <th>You type</th>
            <th>Answer</th>
          </tr>
        </thead>
        <tbody>
          {rows.map(([query, answer]) => (
            <tr key={query}>
              <td><code>{query}</code></td>
              <td>{answer}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export default function Calculator() {
  return (
    <>
      <p className="docs-breadcrumb">
        <a href="/docs">Docs</a> / The calculator
      </p>
      <h1>The calculator</h1>
      <p className="docs-lede">
        Type a question into the launcher and the answer appears as a card at
        the top: your input on the left, the answer on the right, each with a
        short tag. Everything runs on your Mac except exchange rates and
        coin prices.
      </p>

      <h2>Using an answer</h2>
      <ul>
        <li><strong>Return</strong> copies the answer.</li>
        <li>
          <strong>Command-Return</strong> puts the answer in the search field
          so you can keep calculating: <code>2 + 2</code>, Command-Return, then
          {' '}<code>* 3</code>.
        </li>
        <li>
          <strong>Shift-Command-Return</strong> runs a conversion the other
          way: <code>5 km in mi</code> becomes <code>3.106856 mi in km</code>.
        </li>
      </ul>

      <h2>Arithmetic</h2>
      <Examples
        rows={[
          ['2^10 / 3', '341.3333333333'],
          ['-2^2', '-4, as written math reads it'],
          ['10 mod 3', '1 (% always means percent)'],
          ['sin(90°)', '1 (radians unless marked °, deg)'],
          ['cube root of 343', '7'],
          ['5!', '120'],
          ['max(3, 7, 5)', '7'],
          ['median(7, 3, 9, 4)', '5.5'],
          ['sum of 12, 30 and 8', '50'],
          ['nCr(10, 3)', '120'],
          ['ratio of 1920 to 1080', '1.7777777778, tagged 16:9'],
          ['2^64', '1.8446744074e19'],
          ["what's 7 * 6?", '42'],
          ['3 * (4 + 5', '27, with the missing parenthesis closed'],
        ]}
      />
      <p>
        Functions include <code>sqrt</code>, <code>cbrt</code>,{' '}
        <code>abs</code>, <code>round</code>, <code>floor</code>,{' '}
        <code>ceil</code>, trigonometric and hyperbolic functions and their
        inverses, <code>ln</code>, <code>log</code>, <code>log2</code>,{' '}
        <code>exp</code>, <code>min</code>, <code>max</code>,{' '}
        <code>avg</code>, <code>sum</code>, <code>median</code>,{' '}
        <code>range</code>, <code>stdev</code>, <code>atan2</code>,{' '}
        <code>hypot</code>, <code>gcd</code>, <code>lcm</code>,{' '}
        <code>nCr</code> and <code>nPr</code>.
      </p>
      <p>
        Numbers follow your Mac&rsquo;s region: <code>1,000</code> in English,
        {' '}<code>2,5</code> in German, <code>1 000</code> in French.
        Scientific notation (<code>1e3</code>) and magnitudes
        (<code>25K</code>, <code>2.5 million</code>) work too. Very large and
        very small results switch to scientific notation rather than show
        digits a computer can&rsquo;t vouch for.
      </p>

      <h2>Percentages and money</h2>
      <Examples
        rows={[
          ['35% of 260', '91'],
          ['25% off 64', '48'],
          ['18% tip on $65', '$76.70, tagged with the $11.70 tip'],
          ['100 - 10%', '90'],
          ['30 is what percent of 120', '25%'],
          ['increase from 40 to 50', '+25%'],
          ['3/4 in percent', '75%'],
          ['$1,200 / 4', '$300.00'],
          ['€50 + €20', '€70.00'],
          ['10 usd + 5 eur in usd', 'each amount converted first'],
          ['$45/hour * 37.5 hours', '$1,687.50'],
          ['half of $80', '$40.00'],
          ['a third of 2 hours', '40 minutes'],
        ]}
      />
      <p>
        Amounts in one currency need no exchange rates; mixing currencies
        uses the same rates as a conversion. Writing{' '}
        <code>percent</code> or <code>pct</code> works anywhere{' '}
        <code>%</code> does.
      </p>

      <h2>Units</h2>
      <Examples
        rows={[
          ['5 km in mi', '3.106856 mi'],
          ['72f to c', '22.222222 °C'],
          ['98.6 f', '37 °C, with no target needed'],
          ['2 lb 6 oz in kg', '1.077282 kg'],
          ['6\'1" in cm', '185.42 cm'],
          ['100 Mbps in MB/s', '12.5 MB/s'],
          ['35 mpg in l/100km', '6.720417 L/100 km'],
          ['10 km / 48 min', '12.5 km/h'],
          ['(3kg + 5lbs) * 2 in oz', '371.643772 oz'],
          ['(1 mi + 1 km) / 8 min', '12.160284 mph'],
          ['1013.25 hPa in atm', '1 atm'],
          ['mach 1.5 in mph', 'about 1,142 mph, at sea level'],
          ['3.26 ly in pc', '0.999521 pc'],
          ['48px in rem at 12px', '4rem'],
          ['3 cm in px at 300 dpi', '354.3307px'],
        ]}
      />
      <p>
        Length, mass, volume, temperature, area, data and data rates, speed,
        fuel economy, energy, power, pressure, duration and astronomical
        distances convert with exact definitions, and quantities add up across
        units. CSS and design units use CSS&rsquo;s fixed ratios, with{' '}
        <code>at 18px</code> for a different rem base and{' '}
        <code>at 300 dpi</code> for print.
      </p>

      <h2>Cooking</h2>
      <Examples
        rows={[
          ['1 1/2 cups bread flour in g', '180 g'],
          ['300 g brown sugar in cups', '1.41 cups, about 1⅜'],
          ['2 sticks butter in grams', '226 g'],
          ['1 tbsp kosher salt in grams', 'one card per brand'],
          ['200°C in gas mark', 'Gas mark 6'],
        ]}
      />
      <p>
        About 55 ingredients convert between volume and weight using King
        Arthur Baking&rsquo;s ingredient weight chart. Answers are tagged as
        approximate, and an ingredient Volant doesn&rsquo;t know gets no
        answer rather than a guess.
      </p>

      <h2>Time zones</h2>
      <Examples
        rows={[
          ['1pm EST in CET', '7:00 PM CEST'],
          ['3pm Lisbon in Tokyo', '11:00 PM in Tokyo'],
          ['5pm pst in ist', 'one card each for India, Ireland and Israel'],
          ['noon in Denver', 'noon there, in your time'],
          ['time in JFK', 'the time in New York, by airport code'],
          ['time diff Sydney', 'how far ahead or behind your clock it is'],
          ['time in 90 minutes in Denver', 'the clock there later'],
          ['2024-03-15T14:30:00Z', 'the timestamp in your time'],
          ['unix 1700000000', 'a Unix time in your time'],
        ]}
      />
      <p>
        Zone abbreviations follow daylight saving the way people use them, and
        the answer names the one in effect. About 34,000 city names and 7,900
        airport codes work offline. When a city name or zone abbreviation is
        ambiguous, such as Springfield or IST, you get one card per likely
        place instead of a guess. A time that clocks skip on a
        daylight-saving change explains the jump and converts the nearest
        valid time, and a time that happens twice gives one card for each
        reading, such as EDT and EST.
      </p>

      <h2>Dates and durations</h2>
      <Examples
        rows={[
          ['7:30pm tomorrow', 'Tomorrow at 7:30 PM'],
          ['next friday', 'the next Friday that is not today'],
          ['days until christmas', 'a count, tagged with the date'],
          ['workdays until Dec 25', 'skips your region’s public holidays'],
          ['in 10 business days', 'a date'],
          ['friday in 2 weeks', 'that Friday'],
          ['March 3 + 10', 'March 13'],
          ['Nov 26 - Sep 1', '86 days'],
          ['8:45am to 5:15pm', '8 hours 30 minutes'],
          ['11pm to 7am', '8 hours, across midnight'],
          ['2h 20min + 55min', '3 hours 15 minutes'],
          ['200 mins to timespan', '3 hours 20 minutes'],
          ['workhours in 2027', 'the year’s 8-hour workdays, in hours'],
          ['40h in workdays', '5 workdays'],
        ]}
      />
      <Examples
        rows={[
          ['what day was 1999-12-31', 'Friday'],
          ['week number of Jan 1 2027', 'Week 53 of 2026 (ISO weeks)'],
          ['days in Feb 2028', '29 days'],
          ['is 2100 a leap year', 'No'],
          ['age 1990-06-15', 'years, and days to the next birthday'],
        ]}
      />
      <p>
        Workdays skip public holidays for the US, the UK (England and Wales),
        Germany, France and Canada, and only weekends elsewhere; the card says
        which. Named holidays such as Easter, Thanksgiving, Memorial Day and
        Boxing Day work wherever a date does.
      </p>

      <h2>Number forms</h2>
      <Examples
        rows={[
          ['0x1F + 0b1010', '41'],
          ['4095 in binary', '0b1111 1111 1111'],
          ['0x2A in decimal', '42'],
          ['2.75 as mixed number', '2 3/4'],
          ['pi as fraction', '355/113, tagged approximate'],
          ['2026 in roman', 'MMXXVI'],
          ['roman numeral MMXXVI', '2026'],
        ]}
      />

      <h2>Colors</h2>
      <Examples
        rows={[
          ['#3a7bd5', 'rgb(58 123 213), with a swatch'],
          ['hsl(120 100% 50%)', '#00ff00'],
          ['#ff0000 in oklch', 'oklch(62.8% 0.2577 29.23)'],
          ['rebeccapurple in hex', '#663399'],
          ['#3a7bd5 desaturate 30%', '#5e81b1'],
          ['complement of #3a7bd5', '#d5943a'],
          ['#3a7bd5 at 50% alpha', '#3a7bd580'],
          ['mix(#f00, #00f)', '#8c53a2, mixed in OKLab'],
          ['contrast #fff #3a7bd5', '4.22:1, AA for large text only'],
          ['#3a7bd5 in swiftui', 'Color(red: 0.227, green: 0.482, blue: 0.835)'],
        ]}
      />
      <p>
        Hex, rgb, hsl, hwb, lab, lch, oklab and oklch convert between each
        other following CSS Color 4, and <code>nscolor</code>,{' '}
        <code>uicolor</code> and <code>swiftui</code> give Swift code.
        Lighten, darken, saturate and desaturate step in HSL the way Sass
        does. Named colors need a target format, so a plain word stays a
        search.
      </p>

      <h2>Currency and crypto</h2>
      <p>
        <code>250 usd in sek</code>, <code>£40 in eur</code> and{' '}
        <code>CHF2.5K in USD</code> convert with the European Central
        Bank&rsquo;s daily reference rates, tagged with their date. Currencies
        the ECB doesn&rsquo;t publish, such as <code>250 aed in eur</code>,
        {' '}<code>5000 twd in jpy</code> or <code>₦50000 in gbp</code>, use
        rates by{' '}
        <a href="https://www.exchangerate-api.com">Exchange Rate API</a>,
        about 160 currencies in all. One conversion always uses a single
        source, and the card shows which. Volant fetches rates through a
        small separate helper the first time you convert a currency that
        needs them, then at most twice a day while you use them, and keeps
        them for offline use.
      </p>
      <p>
        Major coins convert too: <code>0.02 btc in chf</code>,{' '}
        <code>300 gbp in sol</code>. Prices come from CoinGecko the first time
        you convert a coin and refresh at most every ten minutes while you
        convert crypto. No key is needed; a free CoinGecko Demo key in
        Settings → Data &amp; Configuration is optional and gives steadier
        rate limits. Data provided by{' '}
        <a href="https://www.coingecko.com">CoinGecko</a>. See{' '}
        <a href="/docs/privacy-and-security">Privacy and security</a> for what
        these requests send.
      </p>

      <DocFooterNav {...adjacentDocs('calculator')} />
    </>
  );
}
