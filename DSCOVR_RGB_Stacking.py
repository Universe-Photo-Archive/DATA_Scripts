import h5py
import numpy as np
import matplotlib.pyplot as plt
import tkinter as tk

# Screen size function
def get_screen_size():
    root = tk.Tk()
    root.withdraw()  # Hide the tkinter window
    screen_width = root.winfo_screenwidth()
    screen_height = root.winfo_screenheight()
    return screen_width, screen_height

# Ask the user to choose a colour palette
cmap_choice = input("Choose one of the following colour palettes (rainbow, gray, viridis, jet, plasma, inferno, magma, cividis) : ")

# List of valid pallets
valid_cmaps = ['rainbow', 'gray', 'viridis', 'jet', 'plasma', 'inferno', 'magma', 'cividis']

# Confirm the user's choice
if cmap_choice not in valid_cmaps:
    print("Invalid palette, ‘rainbow’ used by default.")
    cmap_choice = 'rainbow'

# Load the HDF5 file
img = h5py.File('epic_1b_20241218144211_03.h5', 'r')

# Initialise the figure with a larger size for the strip images
fig = plt.figure(figsize=(40, 40))  # Overall size of figure

# Band variables
bands = list(img.keys())

# Apply a specific colour palette to each band
rows, cols = 4, 3  # Adjust to give 3 columns and more rows if necessary
i = 1

# Displaying images for each band
for band in bands:
    if 'Image' in img[band]:
        a = fig.add_subplot(rows, cols, i)
        plt.imshow(np.array(img[band]['Image']), cmap=cmap_choice)  # Use the chosen palette
        plt.colorbar()
        a.set_title(band)
        i += 1

# Add narrower spacing between rows
plt.subplots_adjust(hspace=0.5, wspace=0.5)  # Adjusted spacing between images

# Adapt the size of the window to the size of the screen
screen_width, screen_height = get_screen_size()

# If several screens, use the size of the main screen
fig_manager = plt.get_current_fig_manager()

# Adjust the size of the window to the size of the screen
fig_manager.window.geometry(f"{screen_width}x{screen_height}+0+0")  # Position at top left corner

# Displaying tape images
plt.show()

# Selecting bands to create an RGB image
red_band = img['Band680nm']
green_band = img['Band551nm']
blue_band = img['Band443nm']

def get_image(band):
    """Image processing to correct invalid pixels and adjust orientation"""
    img_data = np.ma.fix_invalid(np.array(band['Image']), fill_value=0)
    img_data = np.fliplr(np.rot90(img_data, -1))  # Inverser et faire une rotation
    return img_data

def build_rgb(red, green, blue):
    """Creation of the RGB image by standardising and adjusting the colours"""
    green *= 0.90
    red *= 1.25
    max_value = max(red.max(), green.max(), blue.max())
    rgb = np.dstack((red / max_value, green / max_value, blue / max_value))
    rgb = np.clip(rgb * 1.8, 0, 1)  # Exposure compensation
    return rgb

# Creating the RGB image
rgb_image = build_rgb(get_image(red_band), get_image(green_band), get_image(blue_band))

# Create a new figure for the RGB image
rgb_fig = plt.figure(figsize=(40, 40))  # Figure size for RGB image (larger)
plt.imshow(rgb_image)
plt.title('RGB Image')

# Apply the same window size adjustment for the RGB image
rgb_fig_manager = plt.get_current_fig_manager()
rgb_fig_manager.window.geometry(f"{screen_width}x{screen_height}+0+0")  # Position at top left corner

# RGB image display
plt.show()
