using System;
using System.Collections.Generic;
using System.Drawing;
using System.Text;

// Small fixed-scope QR encoder for the tray pairing URL.
// QR Model 2, Version 4, error-correction level L, byte mode only.
// Capacity is intentionally capped to the Version 4-L byte-mode limit.
internal static class QrCodeV4
{
    private const int Size = 33;
    private const int DataCodewords = 80;
    private const int EccCodewords = 20;

    public static Bitmap Render(string text, int scale)
    {
        if (text == null) throw new ArgumentNullException("text");
        if (scale < 4 || scale > 16) throw new ArgumentOutOfRangeException("scale");

        byte[] payload = Encoding.UTF8.GetBytes(text);
        if (payload.Length > 78) throw new ArgumentException("Pairing URL is too long for the built-in QR encoder.");

        byte[] data = BuildData(payload);
        byte[] ecc = ReedSolomon(data, EccCodewords);
        byte[] all = new byte[data.Length + ecc.Length];
        Buffer.BlockCopy(data, 0, all, 0, data.Length);
        Buffer.BlockCopy(ecc, 0, all, data.Length, ecc.Length);

        bool[,] functions;
        bool[,] baseModules = BuildBase(out functions);
        PlaceData(baseModules, functions, all);

        bool[,] best = null;
        int bestPenalty = Int32.MaxValue;
        for (int mask = 0; mask < 8; mask++)
        {
            bool[,] candidate = Copy(baseModules);
            ApplyMask(candidate, functions, mask);
            DrawFormatBits(candidate, functions, mask);
            int penalty = Penalty(candidate);
            if (penalty < bestPenalty)
            {
                bestPenalty = penalty;
                best = candidate;
            }
        }

        return ToBitmap(best, scale, 4);
    }

    private static byte[] BuildData(byte[] payload)
    {
        var bits = new List<bool>(DataCodewords * 8);
        AppendBits(bits, 0x4, 4); // Byte mode
        AppendBits(bits, payload.Length, 8); // Version 1-9 byte-mode count field
        for (int i = 0; i < payload.Length; i++) AppendBits(bits, payload[i], 8);

        int capacity = DataCodewords * 8;
        int terminator = Math.Min(4, capacity - bits.Count);
        for (int i = 0; i < terminator; i++) bits.Add(false);
        while ((bits.Count & 7) != 0) bits.Add(false);

        var result = new List<byte>(DataCodewords);
        for (int i = 0; i < bits.Count; i += 8)
        {
            int value = 0;
            for (int j = 0; j < 8; j++) value = (value << 1) | (bits[i + j] ? 1 : 0);
            result.Add((byte)value);
        }

        bool toggle = false;
        while (result.Count < DataCodewords)
        {
            result.Add(toggle ? (byte)0x11 : (byte)0xEC);
            toggle = !toggle;
        }
        return result.ToArray();
    }

    private static void AppendBits(List<bool> bits, int value, int count)
    {
        for (int i = count - 1; i >= 0; i--) bits.Add(((value >> i) & 1) != 0);
    }

    private static byte[] ReedSolomon(byte[] data, int degree)
    {
        byte[] generator = new byte[] { 1 };
        int root = 1;
        for (int i = 0; i < degree; i++)
        {
            byte[] next = new byte[generator.Length + 1];
            for (int j = 0; j < generator.Length; j++)
            {
                next[j] ^= generator[j];
                next[j + 1] ^= GfMultiply(generator[j], (byte)root);
            }
            generator = next;
            root = GfMultiply((byte)root, 2);
        }

        byte[] work = new byte[data.Length + degree];
        Buffer.BlockCopy(data, 0, work, 0, data.Length);
        for (int i = 0; i < data.Length; i++)
        {
            byte factor = work[i];
            if (factor == 0) continue;
            for (int j = 0; j < generator.Length; j++) work[i + j] ^= GfMultiply(generator[j], factor);
        }

        byte[] ecc = new byte[degree];
        Buffer.BlockCopy(work, data.Length, ecc, 0, degree);
        return ecc;
    }

    private static byte GfMultiply(byte x, byte y)
    {
        int a = x;
        int b = y;
        int result = 0;
        while (b != 0)
        {
            if ((b & 1) != 0) result ^= a;
            b >>= 1;
            a <<= 1;
            if ((a & 0x100) != 0) a ^= 0x11D;
        }
        return (byte)result;
    }

    private static bool[,] BuildBase(out bool[,] functions)
    {
        bool[,] modules = new bool[Size, Size];
        functions = new bool[Size, Size];

        DrawFinder(modules, functions, 3, 3);
        DrawFinder(modules, functions, Size - 4, 3);
        DrawFinder(modules, functions, 3, Size - 4);

        for (int i = 0; i < Size; i++)
        {
            if (!functions[6, i]) SetFunction(modules, functions, i, 6, (i & 1) == 0);
            if (!functions[i, 6]) SetFunction(modules, functions, 6, i, (i & 1) == 0);
        }

        DrawAlignment(modules, functions, 26, 26);
        DrawFormatBits(modules, functions, 0); // reserves and initializes format area
        SetFunction(modules, functions, 8, Size - 8, true); // dark module
        return modules;
    }

    private static void DrawFinder(bool[,] modules, bool[,] functions, int cx, int cy)
    {
        for (int dy = -4; dy <= 4; dy++)
        {
            for (int dx = -4; dx <= 4; dx++)
            {
                int x = cx + dx;
                int y = cy + dy;
                if (x < 0 || y < 0 || x >= Size || y >= Size) continue;
                int dist = Math.Max(Math.Abs(dx), Math.Abs(dy));
                bool black = dist != 2 && dist != 4;
                SetFunction(modules, functions, x, y, black);
            }
        }
    }

    private static void DrawAlignment(bool[,] modules, bool[,] functions, int cx, int cy)
    {
        if (functions[cy, cx]) return;
        for (int dy = -2; dy <= 2; dy++)
            for (int dx = -2; dx <= 2; dx++)
                SetFunction(modules, functions, cx + dx, cy + dy, Math.Max(Math.Abs(dx), Math.Abs(dy)) != 1);
    }

    private static void SetFunction(bool[,] modules, bool[,] functions, int x, int y, bool black)
    {
        modules[y, x] = black;
        functions[y, x] = true;
    }

    private static void DrawFormatBits(bool[,] modules, bool[,] functions, int mask)
    {
        int data = (1 << 3) | mask; // Error correction level L has format bits 01
        int rem = data;
        for (int i = 0; i < 10; i++) rem = (rem << 1) ^ (((rem >> 9) & 1) * 0x537);
        int bits = ((data << 10) | rem) ^ 0x5412;

        for (int i = 0; i <= 5; i++) SetFunction(modules, functions, 8, i, GetBit(bits, i));
        SetFunction(modules, functions, 8, 7, GetBit(bits, 6));
        SetFunction(modules, functions, 8, 8, GetBit(bits, 7));
        SetFunction(modules, functions, 7, 8, GetBit(bits, 8));
        for (int i = 9; i < 15; i++) SetFunction(modules, functions, 14 - i, 8, GetBit(bits, i));

        for (int i = 0; i < 8; i++) SetFunction(modules, functions, Size - 1 - i, 8, GetBit(bits, i));
        for (int i = 8; i < 15; i++) SetFunction(modules, functions, 8, Size - 15 + i, GetBit(bits, i));
        SetFunction(modules, functions, 8, Size - 8, true);
    }

    private static bool GetBit(int value, int bit) { return ((value >> bit) & 1) != 0; }

    private static void PlaceData(bool[,] modules, bool[,] functions, byte[] codewords)
    {
        int bitIndex = 0;
        for (int right = Size - 1; right >= 1; right -= 2)
        {
            if (right == 6) right--;
            for (int vert = 0; vert < Size; vert++)
            {
                int y = (((right + 1) & 2) == 0) ? Size - 1 - vert : vert;
                for (int j = 0; j < 2; j++)
                {
                    int x = right - j;
                    if (functions[y, x]) continue;
                    bool black = false;
                    if (bitIndex < codewords.Length * 8)
                    {
                        int b = codewords[bitIndex >> 3];
                        black = ((b >> (7 - (bitIndex & 7))) & 1) != 0;
                    }
                    modules[y, x] = black;
                    bitIndex++;
                }
            }
        }
    }

    private static void ApplyMask(bool[,] modules, bool[,] functions, int mask)
    {
        for (int y = 0; y < Size; y++)
        {
            for (int x = 0; x < Size; x++)
            {
                if (functions[y, x]) continue;
                bool invert;
                switch (mask)
                {
                    case 0: invert = ((x + y) & 1) == 0; break;
                    case 1: invert = (y & 1) == 0; break;
                    case 2: invert = x % 3 == 0; break;
                    case 3: invert = (x + y) % 3 == 0; break;
                    case 4: invert = ((x / 3) + (y / 2)) % 2 == 0; break;
                    case 5: invert = (x * y) % 2 + (x * y) % 3 == 0; break;
                    case 6: invert = (((x * y) % 2 + (x * y) % 3) & 1) == 0; break;
                    case 7: invert = (((x + y) % 2 + (x * y) % 3) & 1) == 0; break;
                    default: throw new ArgumentOutOfRangeException("mask");
                }
                if (invert) modules[y, x] = !modules[y, x];
            }
        }
    }

    private static int Penalty(bool[,] modules)
    {
        int result = 0;

        for (int y = 0; y < Size; y++)
        {
            bool runColor = modules[y, 0];
            int run = 1;
            for (int x = 1; x < Size; x++)
            {
                if (modules[y, x] == runColor) run++;
                else { if (run >= 5) result += 3 + run - 5; runColor = modules[y, x]; run = 1; }
            }
            if (run >= 5) result += 3 + run - 5;
        }

        for (int x = 0; x < Size; x++)
        {
            bool runColor = modules[0, x];
            int run = 1;
            for (int y = 1; y < Size; y++)
            {
                if (modules[y, x] == runColor) run++;
                else { if (run >= 5) result += 3 + run - 5; runColor = modules[y, x]; run = 1; }
            }
            if (run >= 5) result += 3 + run - 5;
        }

        for (int y = 0; y < Size - 1; y++)
            for (int x = 0; x < Size - 1; x++)
            {
                bool c = modules[y, x];
                if (modules[y, x + 1] == c && modules[y + 1, x] == c && modules[y + 1, x + 1] == c) result += 3;
            }

        for (int y = 0; y < Size; y++)
            for (int x = 0; x <= Size - 11; x++)
                if (FinderLikeRow(modules, y, x)) result += 40;

        for (int x = 0; x < Size; x++)
            for (int y = 0; y <= Size - 11; y++)
                if (FinderLikeColumn(modules, x, y)) result += 40;

        int dark = 0;
        for (int y = 0; y < Size; y++) for (int x = 0; x < Size; x++) if (modules[y, x]) dark++;
        int total = Size * Size;
        result += (Math.Abs(dark * 20 - total * 10) / total) * 10;
        return result;
    }

    private static bool FinderLikeRow(bool[,] m, int y, int x)
    {
        return Pattern(m[y, x], m[y, x + 1], m[y, x + 2], m[y, x + 3], m[y, x + 4], m[y, x + 5], m[y, x + 6], m[y, x + 7], m[y, x + 8], m[y, x + 9], m[y, x + 10]);
    }

    private static bool FinderLikeColumn(bool[,] m, int x, int y)
    {
        return Pattern(m[y, x], m[y + 1, x], m[y + 2, x], m[y + 3, x], m[y + 4, x], m[y + 5, x], m[y + 6, x], m[y + 7, x], m[y + 8, x], m[y + 9, x], m[y + 10, x]);
    }

    private static bool Pattern(bool a, bool b, bool c, bool d, bool e, bool f, bool g, bool h, bool i, bool j, bool k)
    {
        bool p1 = a && !b && c && d && e && !f && g && !h && !i && !j && !k;
        bool p2 = !a && !b && !c && !d && e && !f && g && h && i && !j && k;
        return p1 || p2;
    }

    private static bool[,] Copy(bool[,] source)
    {
        bool[,] result = new bool[Size, Size];
        Array.Copy(source, result, source.Length);
        return result;
    }

    private static Bitmap ToBitmap(bool[,] modules, int scale, int border)
    {
        int pixels = (Size + border * 2) * scale;
        var bmp = new Bitmap(pixels, pixels, System.Drawing.Imaging.PixelFormat.Format24bppRgb);
        using (Graphics g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.White);
            using (Brush black = new SolidBrush(Color.Black))
            {
                for (int y = 0; y < Size; y++)
                    for (int x = 0; x < Size; x++)
                        if (modules[y, x]) g.FillRectangle(black, (x + border) * scale, (y + border) * scale, scale, scale);
            }
        }
        return bmp;
    }
}
