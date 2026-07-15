import SwiftUI

struct StarRatingView: View {
    @Binding var rating: Int

    var label = ""
    var maximumRating = 5

    var offImage = Image(systemName: "star")
    var onImage = Image(systemName: "star.fill")

    var offColor = Color.gray
    var onColor = Color.yellow

    var body: some View {
        HStack {
            ForEach(1..<maximumRating + 1, id: \.self) { number in
                image(for: number)
                    .frame(width: 1)
                    .foregroundStyle(number > rating ? offColor : onColor)
            }
        }
    }

    func image(for number: Int) -> Image {
        number > rating ? offImage : onImage
    }
}

#Preview {
    VStack(alignment: .leading) {
        Text("Genre: Comedy | Duration: 1h05min | Year: 2024")
            .font(.caption)
        StarRatingView(rating: .constant(3))
            .padding()
        Text("Release date: Jan 1, 1994")
            .font(.caption)
    }
}
